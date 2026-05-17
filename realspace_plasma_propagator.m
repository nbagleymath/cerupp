%==========================================================================
% REALSPACE_PLASMA_PROPAGATOR
%==========================================================================
% Advance the core-row plasma density model over one field step and, when
% rho_only_eval=false, return the matching plasma RHS used by the field
% update.
%
% Plasma model summary:
% - This wrapper builds I = |A|^2 on the caller-owned core rows, calls
%   evolve_rho_td(...) to advance rho(t), then assembles the broadband
%   Drude plasma term returned to the field step.
% - Inside evolve_rho_td(...), the staged density RHS is assembled in two
%   pieces before each half/full rho update:
%   * evaluate_rho_ofi_stage_local(...) builds
%       sum_ofi_stage = W_ion(I) [s^-1]
%       rhs_ofi_stage = W_ion(I)*rho_src [m^-3 s^-1]
%   * evolve_rho_td(...) itself builds the reduced avalanche part from
%       W_aval(I) = (sigma_aval_omega_fund/Ui)*I,
%       rhs_aval_stage = W_aval(I)*rho_stage.
% - evolve_rho_td(...) below is the density-update owner. It advances
%     d(rho)/dt = W_ion(I)*rho_src(I,rho) + W_aval(I)*rho
%                 - alpha_recombine*rho^2,
%   with rho_src = max(rho_supply-rho,0) in the remaining-neutral OFI
%   branch or rho_src = rho_ofi_scale in the fixed-density-scale branch.
% - advance_rho_stage_local(...) then applies that staged rho law, either
%   through the explicit Euler/RK2 update or through the exact frozen local
%   stage solve when the exact branch is enabled.
% - The returned plasma RHS uses the envelope current form
%     rhs_plasma(t) = IFFT_t{ sigma_D(omega) .* FFT_t{ (-0.5)*rho(t).*A(t) } },
%   matching the plasma-current term convention used by Couairon et al.,
%   Eur. Phys. J. ST 199, 5-76 (2011).
% - The Drude coefficient supplied here is
%     sigma_D(omega) = (omega_fund/(n(omega)*c*rho_crit))
%                      * (omega_fund*tau_c*(1 + 1i*omega*tau_c)
%                         /(1 + (omega*tau_c)^2)),
%     rho_crit = ep0*m_plasma*omega_fund^2/qe^2,
%   and the reduced avalanche closure uses
%     sigma_aval_omega_fund = Re[sigma_D(omega_fund)].
%
% Local contract:
% - plasma_call is the settled driver/step-owned input surface.
% - Required fields: ion_routine_flag, rho_nt_m3, ui,
%   sigma_vec, sigma_aval_omega_fund, alpha_recombine, dt_vec,
%   plasma_runtime_cfg, plasma_softwarn_state, A_core_in, rho_only_eval.
% - ui is the ionization-energy scalar used by the reduced avalanche law
%   and matched-depletion accounting. The dynamic Keldysh W_ion(I) lookup
%   itself arrives separately through plasma_runtime_cfg.ofi_setup.
% - Optional fields: custom_args for the settled major_step_custom_args.plasma
%   bucket and stage_workspace for reusable start/predictor/rho_end work
%   arrays plus any optional plasma-accounting or Keldysh-evaluation cache
%   buffers the caller is threading forward. rho_peak_only_eval is the
%   optional private rho-end fast path that asks this owner to return only
%   the scalar stage peak when rho_only_eval=true and no rho surface is
%   needed downstream.
% - A_core_in and the returned rhs_plasma_out/rho_core live on core rows [Nc,Nt].
% - stage_workspace_out returns the reusable start/predictor/rho_end
%   workspace surface so the caller can thread it forward when shapes stay
%   compatible.
% - plasma_stiffness_diagnostic returns the per-call sampled stiffness
%   summary used by the stepper when that diagnostic is available;
%   attempted/failed probe counters mark partial records. Otherwise it
%   returns [].
% - plasma_book returns the optional plasma accounting bundle requested by
%   the caller; otherwise it returns [] while keeping the outward ABI fixed.
% - stage_peak_rho_out returns the scalar sampled rho peak from the stage
%   states this plasma call actually evaluates. Peak-only rho-end stages
%   use that scalar without rebuilding the full rho(t) history they would
%   otherwise discard immediately.
% - rho_only_eval=true suppresses rhs_plasma_out. By default it still
%   returns the full core-row rho(t) history [Nc,Nt] needed later by stored
%   plasma diagnostics and depletion-aware NLA; the private
%   rho_peak_only_eval=true path instead returns [] for rho_core and uses
%   stage_peak_rho_out when only the scalar peak is needed.
%
% Notes:
% - Dynamic Keldysh OFI reaches plasma_keldysh_eval(...) through
%   plasma_runtime_cfg.ofi_setup; static MPI uses the same settled OFI
%   surface with prebuilt K/sigma vectors. The separate ui scalar belongs
%   to the reduced avalanche law and matched-depletion accounting, not to
%   the W_ion(I) lookup itself.
% - When exact_avalanche_exp_update_enabled=true, the midpoint/full plasma
%   stages freeze the local OFI/avalanche coefficients over one plasma time
%   substep and solve that frozen local rho ODE in closed form.
%==========================================================================

function [plasma_stiffness_diagnostic, rhs_plasma_out, rho_core, ...
    plasma_softwarn_state, plasma_book, stage_workspace_out, ...
    stage_peak_rho_out] = ...
    realspace_plasma_propagator(plasma_call)
    % I. File-local entry wrapper: unpack the settled plasma call once, then
    % build only the core-row rho/J data that advance_z_step asked to use.

    ion_routine_flag = plasma_call.ion_routine_flag;
    rho_nt_m3 = plasma_call.rho_nt_m3;
    ui = plasma_call.ui;
    sigma_vec = plasma_call.sigma_vec;
    sigma_aval_omega_fund = plasma_call.sigma_aval_omega_fund;
    alpha_recombine = plasma_call.alpha_recombine;
    dt_vec = plasma_call.dt_vec;
    plasma_runtime_cfg = plasma_call.plasma_runtime_cfg;
    plasma_softwarn_state = plasma_call.plasma_softwarn_state;
    A_core_in = plasma_call.A_core_in;
    rho_only_eval = plasma_call.rho_only_eval;
    rho_peak_only_eval = struct_utils.opt_struct_field( ...
        plasma_call, 'rho_peak_only_eval', false);
    stage_workspace = struct_utils.opt_struct_field(plasma_call, 'stage_workspace', struct());
    plasma_custom_args = struct();
    if isfield(plasma_call, 'custom_args') && ~isempty(plasma_call.custom_args)
        plasma_custom_args = plasma_call.custom_args;
    end
    if ~isstruct(plasma_custom_args) || ~isscalar(plasma_custom_args)
        error('realspace_plasma_propagator:InvalidCustomArgs', ...
            'plasma_call.custom_args must be a scalar struct when supplied.');
    end
    need_keldysh_eval_extra_outputs = false;
    if ~(isscalar(rho_peak_only_eval) && ...
            (islogical(rho_peak_only_eval) || isnumeric(rho_peak_only_eval)))
        error('realspace_plasma_propagator:InvalidRhoPeakOnlyEvalFlag', ...
            ['plasma_call.rho_peak_only_eval must be a scalar logical/numeric flag ', ...
             'when supplied.']);
    end
    rho_peak_only_eval = logical(rho_peak_only_eval);
    if rho_peak_only_eval && ~logical(rho_only_eval)
        error('realspace_plasma_propagator:InvalidRhoPeakOnlyEvalFlag', ...
            'rho_peak_only_eval is only valid when rho_only_eval=true.');
    end

    % plasma_runtime_cfg carries runtime policy/config only; the pass-through
    % warning ledger is owned solely by plasma_softwarn_state.
    plasma_softwarn_state = plasma_setup_support.init_state(plasma_softwarn_state);

    % Operate only on the caller-owned [Nc,Nt] core-row field surface.
    if isempty(A_core_in)
        error('realspace_plasma_propagator:MissingACoreInput', ...
            'plasma_call.A_core_in is required and must already be the [Nc,Nt] core-row field surface.');
    end
    A_core = A_core_in;

    % Plasma intensity metric: I = |A|^2.
    i_core = real(A_core .* conj(A_core));
    rho_imag_rel_tol = struct_utils.cerupp_numeric_threshold('rel_tol_tight');

    % evolve_rho_td(...) is the primary helper that computes rho over one
    % z step: it applies the selected OFI, avalanche, recombination, and
    % reservoir rules.
    [rho_core, stage_peak_rho_out, plasma_stiffness_diagnostic, ...
        plasma_softwarn_state, plasma_book, stage_workspace] = evolve_rho_td( ...
        i_core, ion_routine_flag, dt_vec, ...
        rho_nt_m3, ui, sigma_aval_omega_fund, alpha_recombine, ...
        plasma_runtime_cfg, plasma_softwarn_state, stage_workspace, rho_only_eval, ...
        plasma_custom_args, need_keldysh_eval_extra_outputs, ...
        rho_peak_only_eval);
    stage_workspace_out = stage_workspace;

    % Force rho back onto a real density surface before returning it or
    % using it to build the Drude source term.
    rho_core_real = [];
    if ~isempty(rho_core)
        [rho_core, plasma_softwarn_state] = propagation_support.require_real_rho_stage_local( ...
            rho_core, 'rho_core', rho_imag_rel_tol, plasma_softwarn_state, []);
        rho_core_real = rho_core;
    end
    if rho_only_eval
        % rho_only_eval is the caller's "rho only, no plasma RHS" mode used
        % for the private end-of-step rho solve in advance_z_step.

        rhs_plasma_out = [];
        return;
    end

    % Build core-only source J_time_core and apply FFT along time on core rows.
    j_time_core = -0.5 .* rho_core_real .* A_core;  % (Nc x Nt)

    % Plasma current term in the envelope convention of Couairon et al.,
    % Eur. Phys. J. ST 199, 5-76 (2011):
    %   rhs_plasma(t) = IFFT_t{ sigma_D(omega)
    %                           .* FFT_t{ (-0.5)*rho(t).*A(t) } }.
    j_freq_core = fft(j_time_core, [], 2);
    j_freq_core = j_freq_core .* reshape(sigma_vec, 1, []);  % (Nc,Nt)

    % Back to time domain on core rows.
    rhs_plasma_out = ifft(j_freq_core, [], 2);
end

%==========================================================================
% II. File-local helper family: core time-domain rho integrator.
%==========================================================================
% Vectorized core-only rho(t) evolution for one current field step. This is
% where the time-domain plasma density model is actually advanced.
%   d(rho)/dt = W_OFI(I)*max(rho_supply-rho,0) + W_aval(I)*rho - alpha_recombine*rho^2
%               [remaining-neutral OFI source mode]
%   or d(rho)/dt = W_OFI(I)*rho_ofi_scale + W_aval(I)*rho - alpha_recombine*rho^2
%               [fixed-density-scale OFI source mode].
% The time-domain plasma integrator uses either Euler or explicit midpoint,
% selected by plasma_runtime_cfg.plasma_evolve_t_rk2_flag. Both variants use
% one explicit density ceiling plus one source-side neutral reservoir control:
% - rho_stage_cap is the explicit post-stage ceiling enforced after the
%   midpoint and full stage solves.
% - rho_supply = neutral_reservoir_m3 tracks the source-side neutral
%   reservoir seen by the OFI source and by depletion-aware optical
%   accounting only when the selected optical closure uses the
%   remaining-neutral branch.
% - rho_ofi_scale = min(ofi_source_density_scale_m3, rho_supply) is the
%   fixed source-density scale used when
%   plasma_ofi_use_remaining_neutral_factor_flag=false.
% - rho_supply is not a hard stage clamp on rho itself. Avalanche growth
%   can still outrun that one-electron reservoir when rho_stage_cap allows
%   it. The OFI source always clamps its remaining-neutral factor at zero
%   once rho reaches rho_supply; the OFI-based optical sink does so only
%   when the selected NLA closure uses remaining-neutral weighting rather
%   than the fixed rho_ofi_scale branch.
% - rho_stage_cap therefore plays the explicit stage-admissibility role,
%   while rho_supply only says how much one-electron reservoir remains in
%   the OFI source law and in any matched optical depletion branch that
%   chooses remaining-neutral weighting.
% - The explicit midpoint/full RK2 stages, and the optional exact frozen
%   substep solve that can replace them, may return rho_half or rho_next
%   above rho_supply before the later rho_stage_cap clamp runs. Here
%   rho_supply only shuts off the OFI source and any matched optical sink
%   that uses remaining-neutral weighting; it is not a hard density
%   ceiling, so avalanche gain and recombination may still evolve rho above
%   that reservoir level.
% When rho_stage_cap is Inf, the solved state itself has no extra explicit
% finite ceiling beyond the usual nonnegative/finiteness checks.
% Supports OFI-only or OFI+avalanche ionization routines.
%
% Local contract:
% - evolve_rho_td advances the core-row rho(t) surface [Nc,Nt] for one
%   plasma stage from the settled driver-owned intensity, OFI setup, and
%   scalar avalanche/recombination coefficients.
% - The active OFI law is already resolved in plasma_runtime_cfg.ofi_setup:
%   either dynamic Keldysh through the prebuilt Keldysh context or static
%   MPI through prebuilt K/sigma vectors.
% - rho_only_eval=true keeps the end-of-step density-only path light: it
%   skips the later Drude RHS assembly. By default that path still returns
%   the full core-row rho(t) history [Nc,Nt] needed by stored plasma
%   diagnostics and depletion-aware NLA, while rho_peak_only_eval=true
%   keeps only the sampled stage-state peak for private rho-end checks.
% - stage_workspace and plasma_softwarn_state are caller-owned pass-through
%   surfaces. The plasma solve reuses stage_workspace across the current
%   step's start/predictor/rho_end stages, and cerupp.m may thread that
%   workspace forward to later propagation steps when the array shapes stay
%   compatible.
% - rho is clamped into [0, rho_stage_cap] at the checked midpoint/full
%   stages; complex rho is projected back to real(rho), and the worst
%   imaginary leakage is accumulated in plasma_softwarn_state.
% - exact_avalanche_exp_update_enabled switches this live plasma update
%   onto a closed-form substep solve with W_ion(I), W_aval(I), and
%   alpha_recombine frozen over one plasma time interval. That exact branch
%   still uses the same runtime W_ion(I) law and the same rho_supply
%   reservoir choice as the ordinary RK path.
% - Optional per-mechanism OFI / avalanche / recombination accounting is
%   requested through plasma_runtime_cfg.emit_plasma_mechanism_ledgers. On
%   ordinary stored steps that request usually comes from the top-level
%   driver flag enable_drho_xz_diagnostics; on checkpoint-reassembly steps
%   it can also come from checkpoint_diag_reassembly_flag so checkpoint
%   saves carry the extra plasma pieces needed by the offline reassembly
%   helper.
% - Detailed model assumptions remain documented in the manual.
%==========================================================================
function [rho, stage_peak_rho, plasma_stiffness_diagnostic, ...
    plasma_softwarn_state, plasma_book, stage_workspace] = evolve_rho_td( ...
    intens_core, ion_routine_flag, dt_vec, ...
    rho_nt_m3, ui, sigma_aval_omega_fund, alpha_recombine, ...
    plasma_runtime_cfg, plasma_softwarn_state, stage_workspace, rho_only_eval, ...
    plasma_custom_args, need_keldysh_eval_extra_outputs, rho_peak_only_eval)

    % stage_workspace is the caller-owned reusable plasma workspace.
    % The current step reuses those Nc-by-Nt buffers across the start,
    % predictor, and rho_end stages, and the driver may hand the same
    % workspace back on the next propagation step when the shapes still fit.
    if ~(isstruct(stage_workspace) && isscalar(stage_workspace))
        error('realspace_plasma_propagator:InvalidStageWorkspace', ...
            'evolve_rho_td requires stage_workspace to be a scalar struct.');
    end
    % rho_only_eval is the lighter "update rho(t) only" entry used by the
    % end-of-step density checks. That path skips the heavier mechanism
    % ledgers because the caller does not need per-mechanism diagnostics or
    % the Drude RHS surface on that call.

    if ~(isscalar(rho_only_eval) && (islogical(rho_only_eval) || isnumeric(rho_only_eval)))
        error('realspace_plasma_propagator:InvalidRhoOnlyEvalFlag', ...
            'evolve_rho_td requires rho_only_eval to be a scalar logical/numeric flag.');
    end
    rho_only_eval = logical(rho_only_eval);
    if ~(isscalar(rho_peak_only_eval) && ...
            (islogical(rho_peak_only_eval) || isnumeric(rho_peak_only_eval)))
        error('realspace_plasma_propagator:InvalidPeakOnlyRhoFlag', ...
            'evolve_rho_td requires rho_peak_only_eval to be a scalar logical/numeric flag.');
    end
    rho_peak_only_eval = logical(rho_peak_only_eval);
    if rho_peak_only_eval && ~rho_only_eval
        error('realspace_plasma_propagator:InvalidPeakOnlyRhoFlag', ...
            'rho_peak_only_eval is only valid when rho_only_eval=true.');
    end
    if ~isstruct(plasma_custom_args) || ~isscalar(plasma_custom_args)
        error('realspace_plasma_propagator:InvalidEvolveRhoCustomArgs', ...
            'plasma_custom_args must be a scalar struct when supplied to evolve_rho_td.');
    end
    % This owner keeps its own nested custom-arg bucket separate from the
    % deeper Keldysh bucket so user-added rho-step logic can live here
    % without changing the Keldysh-only extension surface.

    evolve_rho_td_custom_args = struct();
    if isfield(plasma_custom_args, 'evolve_rho_td') && ~isempty(plasma_custom_args.evolve_rho_td)
        evolve_rho_td_custom_args = plasma_custom_args.evolve_rho_td;
        if ~isstruct(evolve_rho_td_custom_args) || ~isscalar(evolve_rho_td_custom_args)
            error('realspace_plasma_propagator:InvalidEvolveRhoCustomArgBucket', ...
                'plasma_custom_args.evolve_rho_td must be a scalar struct when supplied.');
        end
    end
    if isfield(plasma_custom_args, 'keldysh') && ~isempty(plasma_custom_args.keldysh)
        keldysh_custom_args = plasma_custom_args.keldysh;
        if ~isstruct(keldysh_custom_args) || ~isscalar(keldysh_custom_args)
            error('realspace_plasma_propagator:InvalidKeldyshCustomArgBucket', ...
                'plasma_custom_args.keldysh must be a scalar struct when supplied.');
        end
    else
        keldysh_custom_args = struct();
    end
    if ~(isscalar(need_keldysh_eval_extra_outputs) && ...
            (islogical(need_keldysh_eval_extra_outputs) || ...
             isnumeric(need_keldysh_eval_extra_outputs)))
        error('realspace_plasma_propagator:InvalidKeldyshExtraOutputFlag', ...
            ['evolve_rho_td requires need_keldysh_eval_extra_outputs to be a ', ...
             'scalar logical/numeric flag.']);
    end
    need_keldysh_eval_extra_outputs = logical(need_keldysh_eval_extra_outputs);
    [nc, nt] = size(intens_core);
    need_rho_history = ~rho_peak_only_eval;
    rho_prev_peakonly = zeros(nc, 1, 'like', intens_core);
    rho_core = [];
    if need_rho_history
        [rho_core, stage_workspace] = prepare_plasma_stage_rho_workspace_local( ...
            stage_workspace, intens_core, nc, nt);
    end
    stage_peak_rho = cast(0, 'like', intens_core);
    % Optional per-mechanism plasma accounting is reset only when the step
    % runtime config asked for it. In the usual driver path that request
    % comes from enable_drho_xz_diagnostics on stored steps or from
    % checkpoint_diag_reassembly_flag on checkpoint-eligible steps. The
    % default path keeps this off so the staged rho solve only pays for the
    % density surface it actually needs.

    need_plasma_book = false;
    full_plasma_bookkeeping_ledger = false;
    if isstruct(plasma_runtime_cfg)
        if isfield(plasma_runtime_cfg, 'need_plasma_bookkeeping_ledger') && ...
                ~isempty(plasma_runtime_cfg.need_plasma_bookkeeping_ledger)
            need_plasma_book = logical(plasma_runtime_cfg.need_plasma_bookkeeping_ledger);
        end
    end
    if rho_only_eval
        need_plasma_book = false;
    end
    if need_plasma_book && isstruct(plasma_runtime_cfg) && ...
            isfield(plasma_runtime_cfg, 'full_bookkeeping_ledger') && ...
            ~isempty(plasma_runtime_cfg.full_bookkeeping_ledger)
        full_plasma_bookkeeping_ledger = logical(plasma_runtime_cfg.full_bookkeeping_ledger);
    end
    emit_plasma_mechanism_ledgers = false;
    if need_plasma_book && isstruct(plasma_runtime_cfg) && ...
            isfield(plasma_runtime_cfg, 'emit_plasma_mechanism_ledgers') && ...
            ~isempty(plasma_runtime_cfg.emit_plasma_mechanism_ledgers)
        emit_plasma_mechanism_ledgers = logical(plasma_runtime_cfg.emit_plasma_mechanism_ledgers);
    end
    need_stage_mechanism_ledgers = need_plasma_book && emit_plasma_mechanism_ledgers;
    plasma_book = [];
    if need_plasma_book
        [plasma_book, stage_workspace] = prepare_plasma_stage_book_workspace_local( ...
            stage_workspace, intens_core, nc, nt, ...
            full_plasma_bookkeeping_ledger, emit_plasma_mechanism_ledgers);
    end
    plasma_stiffness_diagnostic = [];
    if nt < 2
        if need_rho_history
            rho = rho_core;
        else
            rho = [];
        end
        return;
    end

    ion_mode = double(ion_routine_flag);

    % Flags
    use_ofi  = true;
    use_aval = (ion_mode == 1);
    use_exact_aval_exp_update = logical(plasma_runtime_cfg.exact_avalanche_exp_update_enabled);
    use_plasma_time_rk2 = logical(struct_utils.req_struct_field( ...
        plasma_runtime_cfg, 'plasma_evolve_t_rk2_flag', ...
        'realspace_plasma_propagator plasma_runtime_cfg'));

    % Scalars
    % Reduced avalanche closure: use the real carrier-frequency slice of
    % the Drude coefficient
    %   sigma_D(omega) = (omega_fund/(n(omega)*c*rho_crit))
    %                    * (omega_fund*tau_c*(1 + 1i*omega*tau_c)
    %                       /(1 + (omega*tau_c)^2)),
    %   rho_crit = ep0*m_plasma*omega_fund^2/qe^2,
    %   sigma_aval_omega_fund = Re[sigma_D(omega_fund)].
    % This gives W_aval(I) = sigma_aval_omega_fund * I / Ui. The full
    % broadband Drude source is assembled later by the outer wrapper once
    % this rho solve returns.
    sigma_aval = double(sigma_aval_omega_fund);
    avalanche_prefactor = sigma_aval / ui;
    alpha_recombine_scalar = double(alpha_recombine);
    alpha_recombine = cast(alpha_recombine_scalar, 'like', intens_core);
    rho_nt = cast(double(rho_nt_m3), 'like', intens_core);
    rho_stage_cap = cast(Inf, 'like', intens_core);
    rho_stage_cap_cfg = struct_utils.req_struct_field( ...
        plasma_runtime_cfg, 'rho_stage_cap', ...
        'realspace_plasma_propagator plasma_runtime_cfg');
    rho_stage_cap_cfg = double(real(rho_stage_cap_cfg));
    if ~(isscalar(rho_stage_cap_cfg) && isreal(rho_stage_cap_cfg) && ...
            ((isfinite(rho_stage_cap_cfg) && (rho_stage_cap_cfg > 0)) || ...
             (isinf(rho_stage_cap_cfg) && (rho_stage_cap_cfg > 0))))
        error('CerUPP:InvalidPlasmaRhoStageCap', ...
            'plasma_runtime_cfg.rho_stage_cap must be Inf or a finite real scalar > 0.');
    end
    rho_stage_cap = cast(rho_stage_cap_cfg, 'like', intens_core);
    rho_supply_cfg = double(real(struct_utils.req_struct_field( ...
        plasma_runtime_cfg, 'neutral_reservoir_m3', ...
        'realspace_plasma_propagator plasma_runtime_cfg')));
    if ~(isscalar(rho_supply_cfg) && isfinite(rho_supply_cfg) && ...
            isreal(rho_supply_cfg) && (rho_supply_cfg > 0))
        error('CerUPP:InvalidPlasmaNeutralReservoir', ...
            'plasma_runtime_cfg.neutral_reservoir_m3 must be one finite real scalar > 0.');
    end
    rho_supply = cast(rho_supply_cfg, 'like', intens_core);

    dt_vec = dt_vec(:);
    rho_imag_rel_tol = struct_utils.cerupp_numeric_threshold('rel_tol_tight');

    ofi_setup = propagation_support.resolve_prebuilt_ofi_setup_local(plasma_runtime_cfg);
    keldysh_context = ofi_setup.keldysh_ctx;
    k_power = double(ofi_setup.k_power(:).');
    log_sig_k = double(ofi_setup.log_sigK(:).');
    if numel(k_power) ~= numel(log_sig_k)
        error('CerUPP:Plasma:StaticMpiTermLengthMismatch', ...
            ['ofi_setup.k_power and ofi_setup.log_sigK must contain the same ', ...
             'number of static-MPI terms; got %d and %d.'], ...
            numel(k_power), numel(log_sig_k));
    end
    % Keep OFI mode as requested by ion_routine_flag; if no active terms remain
    % after filtering, the OFI sum is naturally zero without forcing a mode switch.

    if isa(intens_core, 'single')
        realmin_like = realmin('single');
        realmax_like = realmax('single');
    else
        realmin_like = realmin('double');
        realmax_like = realmax('double');
    end
    log_min_2 = log(double(realmin_like));
    log_max_2 = log(double(realmax_like)) - 1;
    k_power_ofi = cast(k_power, 'like', intens_core);
    log_sig_k_ofi = cast(log_sig_k, 'like', intens_core);
    realmin_ofi = cast(realmin_like, 'like', intens_core);
    stiffness_diagnostic_enabled = logical(plasma_runtime_cfg.stiffness_diagnostic_enabled);
    stiffness_diagnostic_stride = double(plasma_runtime_cfg.stiffness_diagnostic_stride);
    % diag_local is a sampled worst-case summary rather than a full trace:
    % it keeps the largest sampled W*dt indicators, the matching W maxima,
    % how many stride-selected samples succeeded or failed, and any
    % exponent-health counts accumulated while those stages were evaluated.

    diag_local = struct('ofi_wdt_max',0,'aval_wdt_max',0,'ofi_w_max',0,'aval_w_max',0, ...
                        'dt_at_ofi',NaN,'dt_at_aval',NaN,'sample_count',0, ...
                        'attempted_sample_count',0,'failed_sample_count',0, ...
                        'sample_summary_partial',false,'sample_stride',stiffness_diagnostic_stride, ...
                        'exp_clamp_count', 0, 'exp_clamp_ofi_count', 0, 'exp_clamp_aval_count', 0);
    % Reuse stage-work vectors across time steps to avoid repeated allocations.

    rhs_ofi_prev_rk2  = zeros(nc, 1, 'like', intens_core);
    rhs_ofi_mid_rk2   = zeros(nc, 1, 'like', intens_core);
    if use_aval
        rhs_aval_prev_rk2 = zeros(nc, 1, 'like', intens_core);
        rhs_aval_mid_rk2  = zeros(nc, 1, 'like', intens_core);
        if need_stage_mechanism_ledgers
            drho_aval_step_rk2 = zeros(nc, 1, 'like', intens_core);
        else
            drho_aval_step_rk2 = cast(0, 'like', intens_core);
        end
    else
        % Avalanche disabled (OFI-only): keep scalar zeros to avoid Nc-length clears.

        rhs_aval_prev_rk2 = cast(0, 'like', intens_core);
        rhs_aval_mid_rk2  = cast(0, 'like', intens_core);
        drho_aval_step_rk2 = cast(0, 'like', intens_core);
    end
    sum_ofi_prev_rk2  = zeros(nc, 1, 'like', intens_core);
    sum_ofi_mid_rk2   = zeros(nc, 1, 'like', intens_core);

    use_recomb = (alpha_recombine_scalar ~= 0);
    if use_recomb && need_stage_mechanism_ledgers
        drho_recomb_step_rk2 = zeros(nc, 1, 'like', intens_core);
    else
        drho_recomb_step_rk2 = cast(0, 'like', intens_core);
    end
    % In Keldysh mode dynamic W_ion(I) replaces static MPI accumulation.

    use_static_mpi = use_ofi && ~keldysh_context.enabled;
    keldysh_eval_opts = [];
    if keldysh_context.enabled
        keldysh_eval_opts = propagation_support.build_default_keldysh_eval_opts_local( ...
            keldysh_context, log_min_2, log_max_2);
    end
    ofi_source_mode = resolve_ofi_source_mode_local( ...
        keldysh_context, rho_supply, intens_core);
    keldysh_eval_prev = [];
    keldysh_eval_mid = [];
    for it = 2:nt
        dt = dt_vec(it-1);

        i_prev = intens_core(:, it-1);

        if need_rho_history
            rho_prev = rho_core(:, it-1);
        else
            rho_prev = rho_prev_peakonly;
        end

        % Stage 1 start-of-step RHS assembly:
        % - evaluate_rho_ofi_stage_local(...) builds the OFI law
        %   sum_ofi_prev_rk2 = W_ion(I_prev) and the matching volumetric
        %   source rhs_ofi_prev_rk2.
        % - This owner then builds the reduced avalanche side of the same
        %   stage law from
        %     W_aval(I_prev) = (sigma_aval_omega_fund/ui) * I_prev.
        %   The explicit branch uses
        %     rhs_aval_prev_rk2 = W_aval(I_prev) .* rho_prev,
        %   while the exact frozen branch keeps the coefficient
        %     aval_drive_prev = W_aval(I_prev)
        %   for the later closed-form stage solve.
        if use_aval
            rhs_aval_prev_rk2(:) = 0;
        end
        if need_keldysh_eval_extra_outputs
            [sum_ofi_prev_rk2, rhs_ofi_prev_rk2, avalanche_prefactor_prev, ...
                diag_local, plasma_softwarn_state, keldysh_eval_prev] = ...
                evaluate_rho_ofi_stage_local( ...
                    sum_ofi_prev_rk2, rhs_ofi_prev_rk2, ...
                    i_prev, rho_prev, 'prev', use_ofi, use_static_mpi, ...
                    k_power, k_power_ofi, log_sig_k_ofi, realmin_ofi, ...
                    log_min_2, log_max_2, keldysh_context, keldysh_eval_opts, ...
                    ofi_source_mode, rho_supply, avalanche_prefactor, keldysh_custom_args, ...
                    diag_local, plasma_softwarn_state);
        else
            [sum_ofi_prev_rk2, rhs_ofi_prev_rk2, avalanche_prefactor_prev, ...
                diag_local, plasma_softwarn_state] = ...
                evaluate_rho_ofi_stage_local( ...
                    sum_ofi_prev_rk2, rhs_ofi_prev_rk2, ...
                    i_prev, rho_prev, 'prev', use_ofi, use_static_mpi, ...
                    k_power, k_power_ofi, log_sig_k_ofi, realmin_ofi, ...
                    log_min_2, log_max_2, keldysh_context, keldysh_eval_opts, ...
                    ofi_source_mode, rho_supply, avalanche_prefactor, keldysh_custom_args, ...
                    diag_local, plasma_softwarn_state);
        end
        if use_aval
            if ~use_exact_aval_exp_update
                rhs_aval_prev_rk2(:) = avalanche_prefactor_prev .* i_prev .* rho_prev;
            end
        end

        aval_drive_prev = cast(0, 'like', i_prev);
        if use_aval
            aval_drive_prev = avalanche_prefactor_prev .* i_prev;
        end
        %==================================================================
        % Stiffness diagnostic:
        % Sample only the start-stage rates on the requested stride and keep
        % the worst dimensionless W*dt values seen over the run. These are
        % rough rule-of-thumb review markers, not a second plasma solve or
        % a formal step-acceptance guarantee:
        % - W_OFI,max * dt <= 0.1 often indicates mild step-size pressure
        % - W_OFI,max * dt >= 1 flags a case worth reviewing for possible
        %   overshoot or strong sensitivity
        % - W_aval,max * dt plays the same review role for avalanche growth
        % Any failure here is diagnostic-only and is recorded as a soft warning
        % so the main rho update still finishes.
        %==================================================================

        if stiffness_diagnostic_enabled && ((mod(it-2, stiffness_diagnostic_stride) == 0) || (it == nt))
            diag_local.attempted_sample_count = diag_local.attempted_sample_count + 1;
            try
                if use_ofi
                    % W_OFI(I) here means the active W_ion(I) law [1/s].
                    % For static MPI this reduces to sum_K sigma_K * I^K.

                    w_ofi_max_local = double(max(real(sum_ofi_prev_rk2)));
                else
                    w_ofi_max_local = 0.0;
                end
                if use_aval
                    % W_aval(I) = (Re(sigma_aval_omega_fund)/Ui) * I  [1/s]

                    w_aval_max_local = double(max(real(avalanche_prefactor_prev .* i_prev)));
                else
                    w_aval_max_local = 0.0;
                end

                wdt_ofi_local  = w_ofi_max_local  * double(dt);
                wdt_aval_local = w_aval_max_local * double(dt);

                % Keep only the largest sampled stiffness indicator for each
                % mechanism, together with the dt and raw W value seen there.
                if isfinite(wdt_ofi_local) && (wdt_ofi_local > diag_local.ofi_wdt_max)
                    diag_local.ofi_wdt_max = wdt_ofi_local;
                    diag_local.ofi_w_max   = w_ofi_max_local;
                    diag_local.dt_at_ofi   = double(dt);
                end
                if isfinite(wdt_aval_local) && (wdt_aval_local > diag_local.aval_wdt_max)
                    diag_local.aval_wdt_max = wdt_aval_local;
                    diag_local.aval_w_max   = w_aval_max_local;
                    diag_local.dt_at_aval   = double(dt);
                end
                diag_local.sample_count = diag_local.sample_count + 1;
            catch me
                diag_local.failed_sample_count = diag_local.failed_sample_count + 1;
                diag_local.sample_summary_partial = true;
                plasma_softwarn_state = plasma_setup_support.record_diag_sample_failed( ...
                    plasma_softwarn_state, me);
            end
        end
        %==================================================================

        if use_plasma_time_rk2
            i_curr_rk2 = intens_core(:, it);
            i_mid_rk2  = 0.5 .* (i_prev + i_curr_rk2);
            % Midpoint preview for the RK2 plasma solve:
            % advance rho from rho_prev over one half-step using the
            % start-of-step rates only. The resulting rho_half is the density
            % state seen by the second RK2 stage and therefore controls the
            % completed full-step update and its later accounting split.

            [rho_half, ~, ~, ~, half_clamp_mask, diag_local, plasma_softwarn_state] = ...
                advance_rho_stage_local( ...
                    'half', rho_prev, rho_prev, dt, sum_ofi_prev_rk2, rhs_ofi_prev_rk2, rhs_aval_prev_rk2, ...
                    aval_drive_prev, keldysh_context, ...
                    rho_supply, alpha_recombine, log_min_2, log_max_2, ...
                    rho_stage_cap, rho_imag_rel_tol, i_prev, ...
                    use_exact_aval_exp_update, use_aval, use_recomb, need_stage_mechanism_ledgers, ...
                    drho_aval_step_rk2, drho_recomb_step_rk2, ...
                    diag_local, plasma_softwarn_state, it);

            rho_half_peak = max(real(rho_half(:)), [], 'omitnan');
            if ~isempty(rho_half_peak) && isfinite(double(rho_half_peak))
                stage_peak_rho = max(stage_peak_rho, rho_half_peak);
            end

            % Stage 2 midpoint RHS assembly:
            % - evaluate_rho_ofi_stage_local(...) rebuilds the OFI law at
            %   the midpoint intensity/state, giving
            %   sum_ofi_mid_rk2 = W_ion(I_mid) and rhs_ofi_mid_rk2.
            % - This owner then builds the matching midpoint avalanche term
            %   from
            %     W_aval(I_mid) = (sigma_aval_omega_fund/ui) * I_mid.
            %   The explicit branch uses
            %     rhs_aval_mid_rk2 = W_aval(I_mid) .* rho_half,
            %   while the exact frozen branch keeps
            %     aval_drive_mid = W_aval(I_mid)
            %   for the closed-form full-stage solve.
            if use_aval
                rhs_aval_mid_rk2(:) = 0;
            end
            if need_keldysh_eval_extra_outputs
                [sum_ofi_mid_rk2, rhs_ofi_mid_rk2, avalanche_prefactor_mid, ...
                    diag_local, plasma_softwarn_state, keldysh_eval_mid] = ...
                    evaluate_rho_ofi_stage_local( ...
                        sum_ofi_mid_rk2, rhs_ofi_mid_rk2, ...
                        i_mid_rk2, rho_half, 'mid', use_ofi, use_static_mpi, ...
                        k_power, k_power_ofi, log_sig_k_ofi, realmin_ofi, ...
                        log_min_2, log_max_2, keldysh_context, keldysh_eval_opts, ...
                        ofi_source_mode, rho_supply, avalanche_prefactor, keldysh_custom_args, ...
                        diag_local, plasma_softwarn_state);
            else
                [sum_ofi_mid_rk2, rhs_ofi_mid_rk2, avalanche_prefactor_mid, ...
                    diag_local, plasma_softwarn_state] = ...
                    evaluate_rho_ofi_stage_local( ...
                        sum_ofi_mid_rk2, rhs_ofi_mid_rk2, ...
                        i_mid_rk2, rho_half, 'mid', use_ofi, use_static_mpi, ...
                        k_power, k_power_ofi, log_sig_k_ofi, realmin_ofi, ...
                        log_min_2, log_max_2, keldysh_context, keldysh_eval_opts, ...
                        ofi_source_mode, rho_supply, avalanche_prefactor, keldysh_custom_args, ...
                        diag_local, plasma_softwarn_state);
            end
            if use_aval
                if ~use_exact_aval_exp_update
                    rhs_aval_mid_rk2(:) = avalanche_prefactor_mid .* i_mid_rk2 .* rho_half;
                end
            end

            aval_drive_mid = cast(0, 'like', i_mid_rk2);
            if use_aval
                aval_drive_mid = avalanche_prefactor_mid .* i_mid_rk2;
            end
            [rho_next, drho_ofi_step, drho_aval_step, drho_recomb_step, next_clamp_mask, ...
                diag_local, plasma_softwarn_state] = ...
                advance_rho_stage_local( ...
                    'full', rho_prev, rho_half, dt, sum_ofi_mid_rk2, rhs_ofi_mid_rk2, rhs_aval_mid_rk2, ...
                    aval_drive_mid, keldysh_context, ...
                    rho_supply, alpha_recombine, log_min_2, log_max_2, ...
                    rho_stage_cap, rho_imag_rel_tol, i_mid_rk2, ...
                    use_exact_aval_exp_update, use_aval, use_recomb, need_stage_mechanism_ledgers, ...
                    drho_aval_step_rk2, drho_recomb_step_rk2, ...
                    diag_local, plasma_softwarn_state, it);
        else
            half_clamp_mask = false(size(rho_prev));
            keldysh_eval_mid = [];
            [rho_next, drho_ofi_step, drho_aval_step, drho_recomb_step, next_clamp_mask, ...
                diag_local, plasma_softwarn_state] = ...
                advance_rho_stage_local( ...
                    'full', rho_prev, rho_prev, dt, sum_ofi_prev_rk2, rhs_ofi_prev_rk2, rhs_aval_prev_rk2, ...
                    aval_drive_prev, keldysh_context, ...
                    rho_supply, alpha_recombine, log_min_2, log_max_2, ...
                    rho_stage_cap, rho_imag_rel_tol, i_prev, ...
                    use_exact_aval_exp_update, use_aval, use_recomb, need_stage_mechanism_ledgers, ...
                    drho_aval_step_rk2, drho_recomb_step_rk2, ...
                    diag_local, plasma_softwarn_state, it);
        end
        if need_rho_history
            rho_core(:, it) = rho_next;
        else
            rho_prev_peakonly = rho_next;
        end
        rho_next_peak = max(real(rho_next(:)), [], 'omitnan');
        if ~isempty(rho_next_peak) && isfinite(double(rho_next_peak))
            stage_peak_rho = max(stage_peak_rho, rho_next_peak);
        end
        if need_stage_mechanism_ledgers
            exact_partition_clamp_softwarn = false(size(drho_ofi_step));
            if use_exact_aval_exp_update
                exact_partition_clamp_softwarn = logical(half_clamp_mask | next_clamp_mask);
                if any(exact_partition_clamp_softwarn(:))
                    plasma_softwarn_state = plasma_setup_support.record_rho_clamp_counts( ...
                        plasma_softwarn_state, nnz(exact_partition_clamp_softwarn), ...
                        nnz(half_clamp_mask), nnz(next_clamp_mask), rho_stage_cap);
                end
            end
            plasma_book.drho_ofi_applied(:, it) = drho_ofi_step;
            plasma_book.drho_aval_applied(:, it) = drho_aval_step;
            if isfield(plasma_book, 'drho_recomb_applied')
                plasma_book.drho_recomb_applied(:, it) = drho_recomb_step;
            end
            plasma_book.exact_valid_core(:, it) = isfinite(drho_ofi_step);
        end
    end
    if diag_local.exp_clamp_count > 0
        plasma_softwarn_state = plasma_setup_support.record_exponent_clamp_counts( ...
            plasma_softwarn_state, diag_local.exp_clamp_count, ...
            diag_local.exp_clamp_ofi_count, diag_local.exp_clamp_aval_count);
    end

    if stiffness_diagnostic_enabled
        % Return only the sampled worst-case summary, not the full per-step trace.
        if (diag_local.sample_count == 0) && (diag_local.attempted_sample_count > 0)
            diag_local.ofi_wdt_max = NaN;
            diag_local.aval_wdt_max = NaN;
            diag_local.ofi_w_max = NaN;
            diag_local.aval_w_max = NaN;
            diag_local.dt_at_ofi = NaN;
            diag_local.dt_at_aval = NaN;
        end

        plasma_stiffness_diagnostic = diag_local;
    else
        plasma_stiffness_diagnostic = [];
    end
    if need_rho_history
        stage_workspace.rho_core = rho_core;
    end
    if need_plasma_book
        stage_workspace.plasma_book = plasma_book;
    end
    if need_keldysh_eval_extra_outputs
        stage_workspace.keldysh_eval_prev = keldysh_eval_prev;
        stage_workspace.keldysh_eval_mid = keldysh_eval_mid;
    else
        stage_workspace.keldysh_eval_prev = [];
        stage_workspace.keldysh_eval_mid = [];
    end
    if need_rho_history
        rho = rho_core;
    else
        rho = [];
    end
end

%==========================================================================
% III. File-local helper family: staged OFI and exact stage-update physics.
%==========================================================================
function ofi_source_mode = resolve_ofi_source_mode_local(keldysh_context, rho_supply, like_sample)
% Resolve the step-invariant OFI source weighting once per rho evolve call.

    use_remaining_neutral = logical(struct_utils.opt_struct_field( ...
        keldysh_context, 'plasma_ofi_use_remaining_neutral_factor_flag', ...
        ~struct_utils.opt_struct_field( ...
            keldysh_context, 'keldysh_use_additive_volumetric_source_flag', false)));
    ofi_source_mode = struct( ...
        'use_remaining_neutral', use_remaining_neutral, ...
        'rho_ofi_scale_like', cast(0, 'like', like_sample));
    if ~use_remaining_neutral
        rho_ofi_scale_m3 = double(struct_utils.opt_struct_field( ...
            keldysh_context, 'ofi_source_density_scale_m3', NaN));
        if ~(isscalar(rho_ofi_scale_m3) && isreal(rho_ofi_scale_m3) && ...
                isfinite(rho_ofi_scale_m3) && (rho_ofi_scale_m3 > 0))
            error('CerUPP:InvalidKeldyshSourceDensityScale', ...
                ['Fixed-density-scale Keldysh OFI source requires a finite positive ', ...
                 'keldysh_context.ofi_source_density_scale_m3; got %s.'], ...
                mat2str(rho_ofi_scale_m3));
        end
        ofi_source_mode.rho_ofi_scale_like = cast( ...
            min(rho_ofi_scale_m3, double(rho_supply)), 'like', like_sample);
    end
end

function [exp_arg, underflow_any] = prepare_static_mpi_ofi_exponent_local( ...
    exp_raw, log_min_2, log_max_2, i_stage, stage_tag)
% Static-MPI exponent policy for the stage-level OFI builder above.

    if any(~isfinite(exp_raw(:)))
        error('realspace_plasma_propagator:NonFiniteStaticMPIExponent', ...
            'Static-MPI OFI exponent became non-finite at stage=%s before exp().', stage_tag);
    end
    overflow_mask = (exp_raw > log_max_2);
    if any(overflow_mask(:))
        overflow_idx = find(overflow_mask, 1, 'first');
        error('realspace_plasma_propagator:StaticMPIExponentOverflow', ...
            ['Static-MPI OFI exponent exceeded the safe exp() range at stage=%s ' ...
             '(raw_range=[%.6e, %.6e], allowed=[%.6e, %.6e], first_bad_I=%.6e, first_bad_exp=%.6e). ' ...
             'Refusing a capped finite OFI rate.'], ...
            stage_tag, min(double(exp_raw(:))), max(double(exp_raw(:))), ...
            double(log_min_2), double(log_max_2), ...
            double(i_stage(overflow_idx)), double(exp_raw(overflow_idx)));
    end
    exp_arg = exp_raw;
    underflow_any = any(exp_raw(:) < log_min_2);
    if underflow_any
        exp_arg(exp_raw < log_min_2) = -Inf;
    end
end

function sum_ofi_stage = build_static_mpi_ofi_rate_local( ...
    expo_stage, zero_mask_stage, stage_tag, i_stage, sum_template, log_max_2)
% Assemble static-MPI W_ion(I) without letting the rowwise K reduction
% overflow before the final finite-range check.

    log_rate_limit = log_max_2 + 1;
    if size(expo_stage, 2) == 1
        log_sum_stage = double(expo_stage);
        log_sum_stage(zero_mask_stage) = -Inf;
    else
        expo_stage_d = double(expo_stage);
        row_max = max(expo_stage_d, [], 2);
        log_sum_stage = -Inf(size(row_max));
        active_rows = (~zero_mask_stage) & isfinite(row_max);
        if any(active_rows)
            shifted_stage = expo_stage_d(active_rows, :) - row_max(active_rows);
            sum_shifted_stage = sum(exp(shifted_stage), 2);
            if any(~isfinite(sum_shifted_stage(:)))
                bad_rows = find(active_rows);
                bad_row = bad_rows(find(~isfinite(sum_shifted_stage), 1, 'first'));
                error('realspace_plasma_propagator:StaticMPIRateOverflow', ...
                    ['Static-MPI summed OFI rate reduction became non-finite at stage=%s ' ...
                     '(first_bad_I=%.6e W/m^2, row_max_log_term=%.6e).'], ...
                    stage_tag, double(i_stage(bad_row)), double(row_max(bad_row)));
            end
            log_sum_stage(active_rows) = row_max(active_rows) + log(sum_shifted_stage);
        end
    end
    overflow_mask = (log_sum_stage > log_rate_limit);
    if any(overflow_mask(:))
        overflow_idx = find(overflow_mask, 1, 'first');
        error('realspace_plasma_propagator:StaticMPIRateOverflow', ...
            ['Static-MPI summed OFI rate W_ion(I) exceeded the finite range at stage=%s ' ...
             '(first_bad_I=%.6e W/m^2, first_bad_logW=%.6e, allowed_logW_max=%.6e).'], ...
            stage_tag, double(i_stage(overflow_idx)), ...
            double(log_sum_stage(overflow_idx)), double(log_rate_limit));
    end
    sum_ofi_stage = zeros(size(sum_template), 'like', sum_template);
    finite_mask = isfinite(log_sum_stage);
    if any(finite_mask(:))
        sum_ofi_stage(finite_mask) = cast(exp(log_sum_stage(finite_mask)), 'like', sum_template);
    end
end

function source_density_vec = expand_static_mpi_source_density_local( ...
    source_density_in, sum_ofi_stage, stage_tag)
% Normalize the selected source-density weighting onto the stage-rate shape.

    if isscalar(source_density_in)
        source_density_vec = repmat(cast(source_density_in, 'like', sum_ofi_stage), size(sum_ofi_stage));
    else
        if ~isequal(size(source_density_in), size(sum_ofi_stage))
            error('realspace_plasma_propagator:StaticMPISourceDensityShape', ...
                ['Static-MPI source-density weighting must be scalar or match W_ion(I) at stage=%s; ' ...
                 'got rate size %s and density size %s.'], ...
                stage_tag, mat2str(size(sum_ofi_stage)), mat2str(size(source_density_in)));
        end
        source_density_vec = cast(source_density_in, 'like', sum_ofi_stage);
    end
    if any(~isfinite(source_density_vec(:)))
        bad_idx = find(~isfinite(source_density_vec), 1, 'first');
        error('realspace_plasma_propagator:StaticMPISourceDensityNonFinite', ...
            ['Static-MPI source-density weighting became non-finite at stage=%s ' ...
             '(first_bad_linear_idx=%d, value=%.6e).'], ...
            stage_tag, bad_idx, double(source_density_vec(bad_idx)));
    end
    if any(source_density_vec(:) < 0)
        bad_idx = find(source_density_vec < 0, 1, 'first');
        error('realspace_plasma_propagator:StaticMPISourceDensityNegative', ...
            ['Static-MPI source-density weighting became negative at stage=%s ' ...
             '(first_bad_linear_idx=%d, value=%.6e).'], ...
            stage_tag, bad_idx, double(source_density_vec(bad_idx)));
    end
end

function rhs_ofi_stage = apply_static_mpi_source_density_local( ...
    sum_ofi_stage, source_density_in, stage_tag, i_stage, rhs_template)
% Apply the selected source density to static-MPI W_ion(I) with an early
% overflow guard on the final rho source law.

    source_density_vec = expand_static_mpi_source_density_local( ...
        source_density_in, sum_ofi_stage, stage_tag);
    rhs_ofi_stage = zeros(size(rhs_template), 'like', rhs_template);
    active_mask = (sum_ofi_stage > 0) & (source_density_vec > 0);
    if ~any(active_mask(:))
        return;
    end
    if any(~isfinite(sum_ofi_stage(active_mask)))
        bad_idx = find(active_mask & ~isfinite(sum_ofi_stage), 1, 'first');
        error('realspace_plasma_propagator:StaticMPIRateNonFinite', ...
            ['Static-MPI W_ion(I) became non-finite before source-density weighting at stage=%s ' ...
             '(first_bad_I=%.6e W/m^2, value=%.6e s^-1).'], ...
            stage_tag, double(i_stage(bad_idx)), double(sum_ofi_stage(bad_idx)));
    end
    log_rhs_limit = log(double(realmax(class(rhs_template))));
    active_idx = find(active_mask);
    log_rhs = log(double(sum_ofi_stage(active_idx))) + ...
        log(double(source_density_vec(active_idx)));
    overflow_mask = (log_rhs > log_rhs_limit);
    if any(overflow_mask)
        bad_idx = active_idx(find(overflow_mask, 1, 'first'));
        error('realspace_plasma_propagator:StaticMPISourceOverflow', ...
            ['Static-MPI applied OFI source rhs_ofi_stage exceeded the finite range at stage=%s ' ...
             '(first_bad_I=%.6e W/m^2, W_ion=%.6e s^-1, rho_src=%.6e m^-3, ' ...
             'log_rhs=%.6e, allowed_log_rhs_max=%.6e).'], ...
            stage_tag, double(i_stage(bad_idx)), double(sum_ofi_stage(bad_idx)), ...
            double(source_density_vec(bad_idx)), double(log_rhs(find(overflow_mask, 1, 'first'))), ...
            double(log_rhs_limit));
    end
    rhs_ofi_stage(active_idx) = cast(exp(log_rhs), 'like', rhs_template);
end

function [w, exp_clamp_count, clamp_info, keldysh_eval_extra_outputs] = ...
    eval_keldysh_w_local(i_vals, keldysh_context, eval_opts, log_min_2, log_max_2, keldysh_custom_args)
% Evaluate the dynamic Keldysh law W_ion(I) on one intensity vector.
% This helper only performs the local W_ion(I) call and returns the
% associated lookup-bound clamp counts. The caller still decides how that
% rate enters the current rho stage and how any warnings are surfaced.
% When eval_opts is omitted, use the standard options built from the
% prebuilt Keldysh context and the current safe exp() range. On the
% direct-W path, exp_clamp_count and clamp_info.exp_* stay zero/NaN only
% to preserve the shared caller interface.

    if (nargin < 3) || isempty(eval_opts)
        if nargin < 4 || isempty(log_min_2)
            log_min_2 = log(double(realmin(class(i_vals))));
        end
        if nargin < 5 || isempty(log_max_2)
            log_max_2 = log(double(realmax(class(i_vals)))) - 1;
        end
        eval_opts = propagation_support.build_default_keldysh_eval_opts_local( ...
            keldysh_context, log_min_2, log_max_2);
    end

    [w, exp_clamp_count, clamp_info] = plasma_keldysh_eval( ...
        i_vals, keldysh_context.W_ion_interp_fn, eval_opts);
    if nargout >= 4
        keldysh_eval_extra_outputs = struct( ...
            'custom_args', keldysh_custom_args, ...
            'w', w, ...
            'clamp_info', clamp_info);
    else
        keldysh_eval_extra_outputs = [];
    end
end

function [sum_ofi_stage, rhs_ofi_stage, avalanche_prefactor_stage, ...
    diag_local, plasma_softwarn_state, keldysh_eval_extra_outputs] = ...
    evaluate_rho_ofi_stage_local( ...
    sum_ofi_stage, rhs_ofi_stage, i_stage, rho_stage, stage_tag, use_ofi, use_static_mpi, ...
    k_power, k_power_ofi, log_sig_k_ofi, realmin_ofi, ...
    log_min_2, log_max_2, keldysh_context, keldysh_eval_opts, ...
    ofi_source_mode, ...
    rho_supply, avalanche_prefactor, keldysh_custom_args, ...
    diag_local, plasma_softwarn_state)
% Build the stage-local OFI law for one midpoint/full plasma evaluation.
% The caller has already chosen which ionization family is active. This
% helper turns that choice into the quantities the staged rho ODE actually
% needs at the current half/full stage:
%   sum_ofi_stage : pre-density-scale OFI law W_ion(I) [s^-1]
%   rhs_ofi_stage : applied OFI electron-density source term d(rho)/dt
%                   [m^-3 s^-1] after multiplying W_ion(I) by the selected
%                   source-density weighting
%   plasma_softwarn_state updates for lookup-bound clamp events tied to
%   this stage's OFI evaluation. On the direct W_ion(I) path the shared
%   exp_clamp_count and clamp_info.exp_* placeholders stay zero/NaN and
%   are carried only as compatibility padding for the shared caller surface.

    sum_ofi_stage(:) = 0;
    rhs_ofi_stage(:) = 0;
    keldysh_eval_extra_outputs = [];
    static_mpi_rate_active = false;
    if use_ofi
        stage_key_ofi = plasma_setup_support.eval_stage_key(stage_tag);
        if use_static_mpi && ~isempty(k_power)
            % Static MPI path: evaluate one K term or a summed vector of K
            % terms directly from the staged intensity surface.

            log_i_stage = log(max(i_stage, realmin_ofi));
            zero_mask_stage = (i_stage == 0);
            if numel(k_power) == 1
                expo_stage_raw = log_i_stage .* k_power_ofi + log_sig_k_ofi;
                [expo_stage, underflow_stage] = prepare_static_mpi_ofi_exponent_local( ...
                    expo_stage_raw, log_min_2, log_max_2, i_stage, stage_tag);
                if underflow_stage
                    diag_local.exp_clamp_count = diag_local.exp_clamp_count + 1;
                    diag_local.exp_clamp_ofi_count = diag_local.exp_clamp_ofi_count + 1;
                    plasma_softwarn_state = plasma_setup_support.record_exponent_context_array( ...
                        plasma_softwarn_state, stage_key_ofi, expo_stage_raw, i_stage, log_min_2, log_max_2);
                end
                sum_ofi_stage(:) = build_static_mpi_ofi_rate_local( ...
                    expo_stage, zero_mask_stage, stage_tag, i_stage, sum_ofi_stage, log_max_2);
            else
                expo_stage_raw = log_i_stage * k_power_ofi + log_sig_k_ofi;
                if size(expo_stage_raw, 2) ~= numel(k_power_ofi)
                    error('CerUPP:Plasma:StaticMpiExponentWidthMismatch', ...
                        ['Static-MPI exponent matrix width (%d) must match the ', ...
                         'number of retained K terms (%d) at stage %s.'], ...
                        size(expo_stage_raw, 2), numel(k_power_ofi), stage_tag);
                end
                [expo_stage, underflow_stage] = prepare_static_mpi_ofi_exponent_local( ...
                    expo_stage_raw, log_min_2, log_max_2, i_stage, stage_tag);
                if underflow_stage
                    diag_local.exp_clamp_count = diag_local.exp_clamp_count + 1;
                    diag_local.exp_clamp_ofi_count = diag_local.exp_clamp_ofi_count + 1;
                    plasma_softwarn_state = plasma_setup_support.record_exponent_context_array( ...
                        plasma_softwarn_state, stage_key_ofi, expo_stage_raw, i_stage, log_min_2, log_max_2);
                end
                sum_ofi_stage(:) = build_static_mpi_ofi_rate_local( ...
                    expo_stage, zero_mask_stage, stage_tag, i_stage, sum_ofi_stage, log_max_2);
            end
            static_mpi_rate_active = true;
        end

        if keldysh_context.enabled
            % Dynamic Keldysh path: replace the static MPI sum with the
            % prebuilt W_ion(I) evaluator, then record any intensity-range
            % or LUT-edge clamp events in the stage warning state. The
            % legacy exponent-clamp counter stays zero on this direct-W
            % path.

            if nargout >= 6
                [w_ion_stage, exp_clamp_dyn_stage, clamp_info_stage, keldysh_eval_extra_outputs] = eval_keldysh_w_local( ...
                    i_stage, keldysh_context, keldysh_eval_opts, log_min_2, log_max_2, keldysh_custom_args);
            else
                [w_ion_stage, exp_clamp_dyn_stage, clamp_info_stage] = eval_keldysh_w_local( ...
                    i_stage, keldysh_context, keldysh_eval_opts, log_min_2, log_max_2, keldysh_custom_args);
            end
            if exp_clamp_dyn_stage > 0
                diag_local.exp_clamp_count = diag_local.exp_clamp_count + exp_clamp_dyn_stage;
                diag_local.exp_clamp_ofi_count = diag_local.exp_clamp_ofi_count + exp_clamp_dyn_stage;
                plasma_softwarn_state = plasma_setup_support.record_exponent_context_from_keldysh( ...
                    plasma_softwarn_state, stage_key_ofi, clamp_info_stage);
            end
            plasma_softwarn_state = plasma_setup_support.record_keldysh_lut_clamp( ...
                plasma_softwarn_state, stage_key_ofi, clamp_info_stage);
            sum_ofi_stage(:) = cast(w_ion_stage, 'like', sum_ofi_stage);
            static_mpi_rate_active = false;
        end

        if ~ofi_source_mode.use_remaining_neutral
            if static_mpi_rate_active
                rhs_ofi_stage(:) = apply_static_mpi_source_density_local( ...
                    sum_ofi_stage, ofi_source_mode.rho_ofi_scale_like, ...
                    stage_tag, i_stage, rhs_ofi_stage);
            else
                rhs_ofi_stage(:) = sum_ofi_stage .* ofi_source_mode.rho_ofi_scale_like;
            end
        else
            % Dynamic remaining-neutral weighting (Couairon et al.,
            % EPJ ST 199, 5-76, 2011): the OFI branch shuts off once
            % rho_stage exhausts the current one-electron reservoir
            % rho_supply at this stage.

            rho_supply_like = cast(rho_supply, 'like', rho_stage);
            remaining_neutral_stage = max(rho_supply_like - rho_stage, cast(0, 'like', rho_stage));
            if static_mpi_rate_active
                rhs_ofi_stage(:) = apply_static_mpi_source_density_local( ...
                    sum_ofi_stage, remaining_neutral_stage, stage_tag, i_stage, rhs_ofi_stage);
            else
                rhs_ofi_stage(:) = sum_ofi_stage .* remaining_neutral_stage;
            end
        end
    end

    avalanche_prefactor_stage = avalanche_prefactor;
end

function [rho_out, drho_ofi_step, drho_aval_step, drho_recomb_step, clamp_mask, ...
    diag_local, plasma_softwarn_state] = advance_rho_stage_local( ...
    stage_tag, rho_prev, rho_stage_ref, dt, sum_ofi_stage, rhs_ofi_stage, rhs_aval_stage, aval_drive_stage, ...
    keldysh_context, rho_supply, alpha_recombine, log_min_2, log_max_2, rho_stage_cap, rho_imag_rel_tol, ref_vals, ...
    use_exact_aval_exp_update, use_aval, use_recomb, need_stage_mechanism_ledgers, ...
    drho_aval_step_cache, drho_recomb_step_cache, ...
    diag_local, plasma_softwarn_state, it)
% One staged rho solve for the midpoint/full RK2 plasma update.
% In the explicit branch this helper advances the staged density under
%   d(rho)/dt = rhs_ofi_stage + rhs_aval_stage - alpha_recombine*rho^2
% with a forward-Euler step over either dt/2 or dt. The recombination term
% samples rho_stage_ref: rho_prev for the half stage and rho_half for the
% full stage.
% When exact_avalanche_exp_update_enabled is on, the stage instead freezes
% the OFI / avalanche coefficients and solves the local plasma ODE exactly
% for that stage. In the dynamic remaining-neutral weighting branch this is
%   d(rho)/dt = W_ofi*max(rho_supply-rho,0) + W_aval*rho - alpha_recombine*rho^2,
% so below rho_supply the source-on quadratic law has
% a = W_ofi*rho_supply, b = W_aval-W_ofi, c = alpha_recombine, while above
% rho_supply it switches to the zero-source recombination branch
% a = 0, b = W_aval. In the fixed cap-aware density-scale branch the exact
% stage keeps the source
%   d(rho)/dt = W_ofi*rho_ofi_scale + W_aval*rho - alpha_recombine*rho^2
% with one constant rho_ofi_scale=min(ofi_source_density_scale_m3,rho_supply),
% so there is no rho_supply crossing split inside that OFI term.
% - stage_tag='half' advances rho_prev over dt/2 to build rho_half. This
%   midpoint state is only an RK staging value, so the step-integrated OFI /
%   avalanche / recombination ledgers remain zero/cached here.
% - stage_tag='full' advances rho_prev over dt with midpoint rates to build
%   rho_next and emits the matching full-step OFI / avalanche /
%   recombination ledgers for the current step.
% - rho_stage_ref is only used by the non-exact recombination term:
%   rho_prev for the half stage, rho_half for the full stage.
% - rho_supply is the source-side neutral reservoir inside the OFI law,
%   while rho_stage_cap is the separate explicit admissible ceiling checked
%   after the staged solve. This comment only describes the plasma source-
%   side weighting. The paired OFI-based optical sink may use the same or a
%   different neutral-weighting rule, depending on the selected NLA closure
%   documented in advance_z_step.m.

    stage_tag = char(stage_tag);
    if need_stage_mechanism_ledgers
        drho_ofi_step = zeros(size(rho_prev), 'like', rho_prev);
    else
        drho_ofi_step = cast(0, 'like', rho_prev);
    end
    drho_aval_step = drho_aval_step_cache;
    drho_recomb_step = drho_recomb_step_cache;
    % Stage dispatcher:
    % - 'half' returns the midpoint density used by the outer RK2 plasma step
    % - 'full' returns the end-of-step density and the physical mechanism
    %   ledgers attributed to that current full plasma substep

    switch stage_tag
        case 'half'
            if use_exact_aval_exp_update
                % Exact frozen-coefficient midpoint solve over dt/2.

                [rho_out, diag_local, plasma_softwarn_state] = apply_exact_frozen_rho_update_local( ...
                    rho_prev, 0.5 .* dt, sum_ofi_stage, aval_drive_stage, ...
                    keldysh_context, rho_supply, alpha_recombine, log_min_2, log_max_2, ...
                    'exact_half', ref_vals, diag_local, plasma_softwarn_state);
            else
                % Explicit midpoint predictor:
                %   rho_half = rho_prev + (dt/2) * k_stage
                % with k_stage = rhs_ofi + rhs_aval - alpha*rho_prev^2 when
                % recombination is enabled.

                if use_recomb
                    k_stage = (rhs_ofi_stage + rhs_aval_stage) - alpha_recombine .* (rho_prev.^2);
                else
                    k_stage = rhs_ofi_stage + rhs_aval_stage;
                end
                rho_out = rho_prev + 0.5 .* dt .* k_stage;
            end
            stage_name = 'rho_half';
        case 'full'
            if use_exact_aval_exp_update
                % Exact frozen-coefficient full-step solve over dt.

                [rho_out, diag_local, plasma_softwarn_state] = apply_exact_frozen_rho_update_local( ...
                    rho_prev, dt, sum_ofi_stage, aval_drive_stage, ...
                    keldysh_context, rho_supply, alpha_recombine, log_min_2, log_max_2, ...
                    'exact_full', ref_vals, diag_local, plasma_softwarn_state);
                % The exact stage solve returns rho_prev -> rho_out only.
                % Recover the per-mechanism partition afterward only when the
                % run asked to emit those full-step plasma ledgers.

                if need_stage_mechanism_ledgers
                    try
                        [drho_ofi_step, drho_aval_step, drho_recomb_step] = ...
                            compute_exact_frozen_source_ledgers_local( ...
                                rho_prev, rho_out, dt, sum_ofi_stage, aval_drive_stage, ...
                                keldysh_context, rho_supply, alpha_recombine, ...
                                log_min_2, log_max_2, use_aval, use_recomb);
                    catch me_exact_ledger
                        drho_ofi_step = nan(size(rho_prev), 'like', rho_prev);
                        drho_aval_step = nan(size(rho_prev), 'like', rho_prev);
                        drho_recomb_step = nan(size(rho_prev), 'like', rho_prev);
                        plasma_softwarn_state = plasma_setup_support.record_exact_ledger_replay_failed( ...
                            plasma_softwarn_state, me_exact_ledger);
                    end
                    if use_aval
                        drho_aval_step_cache(:) = drho_aval_step;
                        drho_aval_step = drho_aval_step_cache;
                    end
                    if use_recomb
                        drho_recomb_step_cache(:) = drho_recomb_step;
                        drho_recomb_step = drho_recomb_step_cache;
                    end
                end
            else
                % Explicit full-step update:
                %   rho_next = rho_prev + dt * k_stage
                % and the additive OFI / avalanche / recombination ledgers
                % are recorded directly as dt times their staged source terms.

                if need_stage_mechanism_ledgers
                    drho_ofi_step = dt .* rhs_ofi_stage;
                end
                if use_recomb
                    k_stage = (rhs_ofi_stage + rhs_aval_stage) - alpha_recombine .* (rho_stage_ref.^2);
                    if need_stage_mechanism_ledgers
                        drho_recomb_step_cache(:) = dt .* alpha_recombine .* (rho_stage_ref.^2);
                        drho_recomb_step = drho_recomb_step_cache;
                    end
                else
                    k_stage = rhs_ofi_stage + rhs_aval_stage;
                    drho_recomb_step = drho_recomb_step_cache;
                end
                rho_out = rho_prev + dt .* k_stage;
                if use_aval && need_stage_mechanism_ledgers
                    drho_aval_step_cache(:) = dt .* rhs_aval_stage;
                    drho_aval_step = drho_aval_step_cache;
                end
            end
            stage_name = 'rho_next';
        otherwise
            error('realspace_plasma_propagator:UnknownRhoStageTag', ...
                'Unknown rho stage tag "%s".', stage_tag);
    end

    % Keep non-finite rho as a hard failure, but clamp finite stage
    % overshoots back into [0, rho_stage_cap] so the user-facing
    % rho_plasma_cap knob still behaves as a ceiling.
    [rho_out, plasma_softwarn_state] = propagation_support.require_real_rho_stage_local( ...
        rho_out, stage_name, rho_imag_rel_tol, plasma_softwarn_state, it);
    bad_nonfinite = ~isfinite(rho_out);
    if any(bad_nonfinite(:))
        bad_idx = find(bad_nonfinite, 1, 'first');
        bad_core_row = bad_idx;
        time_idx = double(it);
        if isscalar(dt)
            dt_stage_local = double(dt);
        else
            dt_stage_local = double(dt(bad_idx));
        end
        if strcmp(stage_tag, 'half')
            dt_stage_local = 0.5 .* dt_stage_local;
        end
        if ~isempty(ref_vals)
            i_stage_local = double(ref_vals(bad_idx));
        else
            i_stage_local = NaN;
        end
        rho_prev_local = double(rho_prev(bad_idx));
        rho_stage_ref_local = double(rho_stage_ref(bad_idx));
        rho_out_local = double(rho_out(bad_idx));
        error('realspace_plasma_propagator:NonFiniteRhoStage', ...
            ['rho stage %s produced a non-finite value at linear index %d ', ...
             '(core_row=%d, time_idx=%d, stage_dt=%g s, I_stage=%g W/m^2, ', ...
             'rho_prev=%g m^-3, rho_stage_ref=%g m^-3, rho_out=%g m^-3).'], ...
            stage_name, bad_idx, bad_core_row, time_idx, dt_stage_local, ...
            i_stage_local, rho_prev_local, rho_stage_ref_local, rho_out_local);
    end
    clamp_mask = (rho_out < 0) | (rho_out > rho_stage_cap);
    if any(clamp_mask(:))
        zero_like = cast(0, 'like', rho_out);
        rho_out(clamp_mask) = min(max(rho_out(clamp_mask), zero_like), rho_stage_cap);
        if strcmp(stage_tag, 'full') && need_stage_mechanism_ledgers
            nan_like = cast(NaN, 'like', rho_out);
            drho_ofi_step(clamp_mask) = nan_like;
            if ~isscalar(drho_aval_step)
                drho_aval_step(clamp_mask) = nan_like;
            end
            if ~isscalar(drho_recomb_step)
                drho_recomb_step(clamp_mask) = nan_like;
            end
        end
    end
end

function [rho_out, diag_local, plasma_softwarn_state] = apply_exact_frozen_rho_update_local( ...
    rho_in, dt_step, w_ofi, w_aval, keldysh_context, rho_supply, alpha_recombine, ...
    log_min_2, log_max_2, stage_tag, ref_vals, diag_local, plasma_softwarn_state)
% Exact frozen-coefficient stage solve for the local plasma ODE
% used only when exact_avalanche_exp_update_enabled=true inside
% advance_rho_stage_local. The stage has already frozen W_ofi and W_aval
% at the current half/full-stage intensity, so this helper advances rho
% over that one local dt without adding another Euler/RK truncation inside
% the plasma-time solve.
% The dynamic remaining-neutral branch keeps the source
%   d(rho)/dt = W_ofi*max(rho_supply-rho,0) + W_aval*rho - alpha_recombine*rho^2
% and therefore may switch between source-on/source-off segments at
% rho_supply multiple times inside one plasma substep.
% The fixed cap-aware density-scale branch keeps the source
%   d(rho)/dt = W_ofi*rho_ofi_scale + W_aval*rho - alpha_recombine*rho^2
% with rho_ofi_scale=min(ofi_source_density_scale_m3,rho_supply), so it stays on
% one exact source-on segment with no rho_supply source toggle.

    [rho_out, ~, ~, ~, diag_local, plasma_softwarn_state] = ...
        apply_exact_frozen_rho_update_with_ledgers_local( ...
            rho_in, dt_step, w_ofi, w_aval, keldysh_context, rho_supply, alpha_recombine, ...
            log_min_2, log_max_2, stage_tag, ref_vals, false, false, false, ...
            diag_local, plasma_softwarn_state);
end

function [rho_out, drho_ofi_step, drho_aval_step, drho_recomb_step, ...
    diag_local, plasma_softwarn_state] = ...
    apply_exact_frozen_rho_update_with_ledgers_local( ...
    rho_in, dt_step, w_ofi, w_aval, keldysh_context, rho_supply, alpha_recombine, ...
    log_min_2, log_max_2, stage_tag, ref_vals, use_aval, use_recomb, need_ledgers, ...
    diag_local, plasma_softwarn_state)
% Exact frozen-coefficient stage solve with optional mechanism ledgers.
% The remaining-neutral branch replays the same exact source-on/source-off
% segments until the substep time is exhausted or no further rho_supply
% crossing remains. Any leftover local time after that replay is a hard
% invariant failure for the live rho update, while the diagnostic-only
% ledger rebuild returns invalid mechanism increments and lets the caller
% drop only that optional accounting replay.

    rho0 = rho_in;  % density at the start of this exact local plasma substep
    dt_local = cast(dt_step, 'like', rho0);
    if isscalar(dt_local)
        dt_local = dt_local + zeros(size(rho0), 'like', rho0);  % broadcast scalar dt
                                                                  % across the active entries
    end
    rho_supply_like = cast(rho_supply, 'like', rho0);  % source-toggle boundary
                                                        % for remaining-neutral OFI
    drho_ofi_step = zeros(size(rho0), 'like', rho0);  % optional OFI contribution
                                                       % replayed below
    drho_aval_step = zeros(size(rho0), 'like', rho0);  % optional avalanche
                                                        % contribution replayed below
    drho_recomb_step = zeros(size(rho0), 'like', rho0);  % optional recombination
                                                          % contribution replayed below

    % First choose which OFI source law this exact update should apply.
    plasma_ofi_uses_remaining_neutral = logical(struct_utils.opt_struct_field( ...
        keldysh_context, 'plasma_ofi_use_remaining_neutral_factor_flag', ...
        ~struct_utils.opt_struct_field( ...
            keldysh_context, 'keldysh_use_additive_volumetric_source_flag', false)));
    if ~plasma_ofi_uses_remaining_neutral
        % Fixed-density-scale branch: one exact source-on segment over the
        % whole local dt, with no rho_supply source toggle inside the step.
        rho_ofi_scale = double(struct_utils.opt_struct_field( ...
            keldysh_context, 'ofi_source_density_scale_m3', NaN));
        if ~(isscalar(rho_ofi_scale) && isreal(rho_ofi_scale) && ...
                isfinite(rho_ofi_scale) && (rho_ofi_scale > 0))
            error('realspace_plasma_propagator:InvalidKeldyshSourceDensityScale', ...
                'Fixed-density-scale exact plasma update requires a finite positive ofi_source_density_scale_m3.');
        end
        ref_sub = mask_exact_ref_vals_local(ref_vals, true(size(rho0)));
        rho_ofi_scale = min(rho_ofi_scale, double(rho_supply));
        source_const = w_ofi .* cast(rho_ofi_scale, 'like', rho0);
        [rho_out, diag_local, plasma_softwarn_state] = apply_exact_frozen_ab_update_local( ...
            rho0, dt_local, source_const, w_aval, alpha_recombine, ...
            log_min_2, log_max_2, [stage_tag '_silva_source_on'], ...
            ref_sub, diag_local, plasma_softwarn_state);
        if need_ledgers
            zero_source = zeros(size(rho0), 'like', rho0);
            [drho_ofi_step, drho_aval_step, drho_recomb_step, plasma_softwarn_state] = ...
                try_exact_frozen_segment_ledgers_local( ...
                    rho0, rho_out, dt_local, source_const, w_aval, ...
                    zero_source, w_aval, alpha_recombine, use_aval, ...
                    use_recomb, plasma_softwarn_state);
        end
        return;
    end

    % Remaining-neutral branch: replay exact source-on/source-off segments
    % until the local dt is exhausted.
    rel_tol = struct_utils.cerupp_numeric_threshold('rel_tol_tight');
    rel_tol_like = cast(rel_tol, 'like', rho0);
    one_like = cast(1, 'like', rho0);
    time_tol_floor_mult = cast(32, 'like', rho0);
    tiny_dt_like = cast(realmin(class(dt_local)), 'like', rho0);
    dt_tol_scale = max(abs(dt_local), tiny_dt_like);
    time_abs_floor = time_tol_floor_mult .* ...
        cast(eps(double(dt_tol_scale)), 'like', rho0);
    remaining_tol = rel_tol_like .* abs(dt_local) + time_abs_floor;

    rho_curr = rho0;
    remaining_dt = dt_local;
    source_on_mask = (rho_curr < rho_supply_like);
    boundary_mask = abs(rho_curr - rho_supply_like) <= ...
        rel_tol_like .* max(abs(rho_supply_like), one_like);
    if any(boundary_mask(:))
        % If rho starts numerically on rho_supply, pick the local branch
        % from the post-boundary drift of avalanche minus recombination.
        boundary_drift = w_aval(boundary_mask) .* rho_supply_like - ...
            cast(alpha_recombine, 'like', rho0) .* (rho_supply_like.^2);
        source_on_mask(boundary_mask) = (boundary_drift < 0);
    end

    while true
        active_mask = remaining_dt > remaining_tol;
        if ~any(active_mask(:))
            break;
        end

        active_on = active_mask & source_on_mask;
        if any(active_on(:))
            % Source-on segment: rho is still below the reservoir boundary,
            % so OFI loading is active on this exact sub-interval.
            idx_on = find(active_on);
            rho_on = rho_curr(idx_on);
            dt_on = remaining_dt(idx_on);
            w_ofi_on = w_ofi(idx_on);
            w_aval_on = w_aval(idx_on);
            source_const_on = w_ofi_on .* rho_supply_like;
            source_gain_on = w_aval_on - w_ofi_on;
            ref_on = mask_exact_ref_vals_local(ref_vals, active_on);
            [rho_trial, diag_local, plasma_softwarn_state] = apply_exact_frozen_ab_update_local( ...
                rho_on, dt_on, source_const_on, source_gain_on, ...
                alpha_recombine, log_min_2, log_max_2, ...
                [stage_tag '_source_on_seg'], ref_on, ...
                diag_local, plasma_softwarn_state);
            cross_up_mask = (rho_trial > rho_supply_like);
            keep_on = ~cross_up_mask;
            if any(keep_on(:))
                keep_idx = idx_on(keep_on);
                rho_curr(keep_idx) = rho_trial(keep_on);
                remaining_dt(keep_idx) = 0;
                if need_ledgers
                    [dr_ofi_sub, dr_aval_sub, dr_recomb_sub, plasma_softwarn_state] = ...
                        try_exact_frozen_segment_ledgers_local( ...
                            rho_on(keep_on), rho_trial(keep_on), dt_on(keep_on), ...
                            source_const_on(keep_on), source_gain_on(keep_on), ...
                            w_ofi_on(keep_on), w_aval_on(keep_on), ...
                            alpha_recombine, use_aval, use_recomb, ...
                            plasma_softwarn_state);
                    drho_ofi_step(keep_idx) = drho_ofi_step(keep_idx) + dr_ofi_sub;
                    drho_aval_step(keep_idx) = drho_aval_step(keep_idx) + dr_aval_sub;
                    drho_recomb_step(keep_idx) = drho_recomb_step(keep_idx) + dr_recomb_sub;
                end
            end
            if any(cross_up_mask(:))
                cross_idx = idx_on(cross_up_mask);
                t_cross = find_exact_frozen_crossing_time_local( ...
                    rho_on(cross_up_mask), rho_supply_like, dt_on(cross_up_mask), ...
                    source_const_on(cross_up_mask), source_gain_on(cross_up_mask), ...
                    alpha_recombine, true);
                next_remaining = dt_on(cross_up_mask) - t_cross;
                next_remaining = max(next_remaining, 0);
                if need_ledgers
                    rho_supply_vec = rho_supply_like + zeros(size(t_cross), 'like', t_cross);
                    [dr_ofi_sub, dr_aval_sub, dr_recomb_sub, plasma_softwarn_state] = ...
                        try_exact_frozen_segment_ledgers_local( ...
                            rho_on(cross_up_mask), rho_supply_vec, t_cross, ...
                            source_const_on(cross_up_mask), source_gain_on(cross_up_mask), ...
                            w_ofi_on(cross_up_mask), w_aval_on(cross_up_mask), ...
                            alpha_recombine, use_aval, use_recomb, ...
                            plasma_softwarn_state);
                    drho_ofi_step(cross_idx) = drho_ofi_step(cross_idx) + dr_ofi_sub;
                    drho_aval_step(cross_idx) = drho_aval_step(cross_idx) + dr_aval_sub;
                    drho_recomb_step(cross_idx) = drho_recomb_step(cross_idx) + dr_recomb_sub;
                end
                boundary_drift = w_aval_on(cross_up_mask) .* rho_supply_like - ...
                    cast(alpha_recombine, 'like', rho0) .* (rho_supply_like.^2);
                rho_curr(cross_idx) = rho_supply_like;
                remaining_dt(cross_idx) = next_remaining;
                source_on_mask(cross_idx) = (boundary_drift < 0);
            end
        end

        active_off = (remaining_dt > remaining_tol) & ~source_on_mask;
        if any(active_off(:))
            % Source-off segment: rho has reached/exceeded rho_supply, so
            % only avalanche and recombination remain active here.
            idx_off = find(active_off);
            rho_off = rho_curr(idx_off);
            dt_off = remaining_dt(idx_off);
            w_ofi_off = w_ofi(idx_off);
            w_aval_off = w_aval(idx_off);
            zero_source_off = zeros(size(rho_off), 'like', rho_off);
            ref_off = mask_exact_ref_vals_local(ref_vals, active_off);
            [rho_trial, diag_local, plasma_softwarn_state] = apply_exact_frozen_ab_update_local( ...
                rho_off, dt_off, zero_source_off, w_aval_off, ...
                alpha_recombine, log_min_2, log_max_2, ...
                [stage_tag '_source_off_seg'], ref_off, ...
                diag_local, plasma_softwarn_state);
            cross_down_mask = (rho_trial < rho_supply_like);
            keep_off = ~cross_down_mask;
            if any(keep_off(:))
                keep_idx = idx_off(keep_off);
                rho_curr(keep_idx) = rho_trial(keep_off);
                remaining_dt(keep_idx) = 0;
                if need_ledgers
                    [dr_ofi_sub, dr_aval_sub, dr_recomb_sub, plasma_softwarn_state] = ...
                        try_exact_frozen_segment_ledgers_local( ...
                            rho_off(keep_off), rho_trial(keep_off), dt_off(keep_off), ...
                            zero_source_off(keep_off), w_aval_off(keep_off), ...
                            zero_source_off(keep_off), w_aval_off(keep_off), ...
                            alpha_recombine, use_aval, use_recomb, ...
                            plasma_softwarn_state);
                    drho_ofi_step(keep_idx) = drho_ofi_step(keep_idx) + dr_ofi_sub;
                    drho_aval_step(keep_idx) = drho_aval_step(keep_idx) + dr_aval_sub;
                    drho_recomb_step(keep_idx) = drho_recomb_step(keep_idx) + dr_recomb_sub;
                end
            end
            if any(cross_down_mask(:))
                cross_idx = idx_off(cross_down_mask);
                t_cross = find_exact_frozen_crossing_time_local( ...
                    rho_off(cross_down_mask), rho_supply_like, dt_off(cross_down_mask), ...
                    zero_source_off(cross_down_mask), w_aval_off(cross_down_mask), ...
                    alpha_recombine, false);
                next_remaining = dt_off(cross_down_mask) - t_cross;
                next_remaining = max(next_remaining, 0);
                if need_ledgers
                    rho_supply_vec = rho_supply_like + zeros(size(t_cross), 'like', t_cross);
                    [dr_ofi_sub, dr_aval_sub, dr_recomb_sub, plasma_softwarn_state] = ...
                        try_exact_frozen_segment_ledgers_local( ...
                            rho_off(cross_down_mask), rho_supply_vec, t_cross, ...
                            zero_source_off(cross_down_mask), ...
                            w_aval_off(cross_down_mask), ...
                            zero_source_off(cross_down_mask), ...
                            w_aval_off(cross_down_mask), ...
                            alpha_recombine, use_aval, use_recomb, ...
                            plasma_softwarn_state);
                    drho_ofi_step(cross_idx) = drho_ofi_step(cross_idx) + dr_ofi_sub;
                    drho_aval_step(cross_idx) = drho_aval_step(cross_idx) + dr_aval_sub;
                    drho_recomb_step(cross_idx) = drho_recomb_step(cross_idx) + dr_recomb_sub;
                end
                boundary_drift = w_aval_off(cross_down_mask) .* rho_supply_like - ...
                    cast(alpha_recombine, 'like', rho0) .* (rho_supply_like.^2);
                rho_curr(cross_idx) = rho_supply_like;
                remaining_dt(cross_idx) = next_remaining;
                source_on_mask(cross_idx) = (boundary_drift < 0);
            end
        end
    end

    remaining_dt(remaining_dt <= remaining_tol) = 0;
    unresolved_mask = remaining_dt > 0;
    if any(unresolved_mask(:))
        unresolved_count = nnz(unresolved_mask);
        max_remaining_dt = max(double(remaining_dt(unresolved_mask)));
        if need_ledgers
            drho_ofi_step(unresolved_mask) = nan;
            drho_aval_step(unresolved_mask) = nan;
            drho_recomb_step(unresolved_mask) = nan;
        end
        diagnostic_only_replay = need_ledgers && strcmp(stage_tag, 'exact_ledger_rebuild');
        if ~diagnostic_only_replay
            error('realspace_plasma_propagator:ExactFrozenRemainingDtUnresolved', ...
                ['Exact frozen remaining-neutral replay left unresolved local time at stage=%s ', ...
                 'for %d entries (max remaining dt=%.3g s) after the branch-split solve.'], ...
                stage_tag, unresolved_count, max_remaining_dt);
        end
    end
    rho_out = cast(rho_curr, 'like', rho_in);
end

function [rho_out, diag_local, plasma_softwarn_state] = apply_exact_frozen_ab_update_local( ...
    rho_in, dt_step, a, b, alpha_recombine, ...
    log_min_2, log_max_2, stage_tag, ref_vals, diag_local, plasma_softwarn_state)
% Exact frozen-coefficient solve for one local segment
%   d(rho)/dt = a + b*rho - alpha_recombine*rho^2.

    c_scalar = double(alpha_recombine);  % recombination coefficient used for
                                         % branch selection
    rho_cls = class(rho_in);
    c = cast(c_scalar, 'like', rho_in);
    dt_local = cast(dt_step, 'like', rho_in);
    if isscalar(dt_local)
        dt_local = dt_local + zeros(size(rho_in), 'like', rho_in);  % broadcast scalar dt
                                                                     % across the segment vector
    end
    rho0 = rho_in;  % density at the start of this exact segment
    rho_next = zeros(size(rho0), 'like', rho0);  % segment-end density built branch by branch
    rel_tol = struct_utils.cerupp_numeric_threshold('rel_tol_tight');
    rel_tol_like = cast(rel_tol, 'like', rho0);
    zero_like = cast(0, 'like', rho0);
    one_like = cast(1, 'like', rho0);
    two_like = cast(2, 'like', rho0);
    four_like = cast(4, 'like', rho0);
    tiny_like = cast(realmin(rho_cls), 'like', rho0);
    branch_cases = exact_frozen_branch_cases(a, b, c_scalar, rel_tol_like, one_like);

    if branch_cases.affine_problem
        % No recombination: the exact update reduces to affine growth/decay.
        small_b = branch_cases.small_b_mask;
        affine_mask = branch_cases.affine_mask;
        rho_next(small_b) = rho0(small_b) + dt_local(small_b) .* a(small_b);
        if any(affine_mask(:))
            exp_raw = b(affine_mask) .* dt_local(affine_mask);
            [exp_vals, diag_local, plasma_softwarn_state] = exact_update_exp_local( ...
                exp_raw, [stage_tag '_affine'], mask_exact_ref_vals_local(ref_vals, affine_mask), ...
                log_min_2, log_max_2, diag_local, plasma_softwarn_state);
            b_aff = b(affine_mask);
            a_aff = a(affine_mask);
            rho_aff = rho0(affine_mask);
            rho_next(affine_mask) = (rho_aff + a_aff ./ b_aff) .* exp_vals - a_aff ./ b_aff;
        end
        rho_out = cast(rho_next, 'like', rho_in);
        return;
    end

    zero_source_mask = branch_cases.zero_source_mask;
    if any(zero_source_mask(:))
        % Zero-source branch: OFI loading is off, so only the homogeneous
        % avalanche/recombination part of the frozen ODE remains.
        b_zero = b(zero_source_mask);
        rho_zero = rho0(zero_source_mask);
        ref_zero = mask_exact_ref_vals_local(ref_vals, zero_source_mask);
        dt_zero = dt_local(zero_source_mask);
        small_b_zero = branch_cases.small_b_zero;
        rho_next_zero = zeros(size(rho_zero), 'like', rho_zero);
        if any(small_b_zero(:))
            rho_small = rho_zero(small_b_zero);
            dt_small = dt_zero(small_b_zero);
            rho_next_zero(small_b_zero) = rho_small ./ max(one_like + c .* rho_small .* dt_small, tiny_like);
        end
        nonsmall_zero = ~small_b_zero;
        if any(nonsmall_zero(:))
            exp_raw = b_zero(nonsmall_zero) .* dt_zero(nonsmall_zero);
            [exp_vals, diag_local, plasma_softwarn_state] = exact_update_exp_local( ...
                exp_raw, [stage_tag '_logistic'], ref_zero(nonsmall_zero), ...
                log_min_2, log_max_2, diag_local, plasma_softwarn_state);
            b_sub = b_zero(nonsmall_zero);
            rho_sub = rho_zero(nonsmall_zero);
            denom = 1 + (c .* rho_sub ./ b_sub) .* (exp_vals - 1);
            if any(~isfinite(denom(:)) | (denom(:) == 0))
                error('realspace_plasma_propagator:ExactFrozenUpdateInvalidDenominator', ...
                    'Exact frozen logistic update produced an invalid denominator at stage=%s.', stage_tag);
            end
            rho_next_zero(nonsmall_zero) = (rho_sub .* exp_vals) ./ denom;
        end
        rho_next(zero_source_mask) = rho_next_zero;
    end

    source_on_mask = branch_cases.source_on_mask;
    if any(source_on_mask(:))
        % Source-on branch: keep the full frozen source term a together with
        % avalanche/recombination in the closed-form quadratic solution.
        a_sub = a(source_on_mask);
        b_sub = b(source_on_mask);
        rho_sub = rho0(source_on_mask);
        dt_sub = dt_local(source_on_mask);
        delta = sqrt(max(b_sub.^2 + four_like .* c .* a_sub, zero_like));
        exp_neg = exp(-delta .* dt_sub);
        rho_plus = (b_sub + delta) ./ (two_like .* c);
        rho_minus = (b_sub - delta) ./ (two_like .* c);
        denom0 = rho_sub - rho_minus;
        scale0 = max(one_like, max(abs(rho_sub), abs(rho_minus)));
        if any(abs(denom0(:)) <= rel_tol_like .* scale0)
            error('realspace_plasma_propagator:ExactFrozenUpdateSingularInit', ...
                'Exact frozen source-on update encountered a singular initial denominator at stage=%s.', stage_tag);
        end
        q0 = (rho_sub - rho_plus) ./ denom0;
        exp_arg = -delta .* dt_sub;

        % Use a stable 1-q evaluation when q0*exp(-delta*dt) is close to 1.
        % Large carried-over rho can make the denominator tiny without
        % making the exact source-on solution itself singular.
        denom = (delta ./ c) ./ denom0 - q0 .* expm1(exp_arg);
        if any(~isfinite(denom(:)) | (denom(:) == 0))
            error('realspace_plasma_propagator:ExactFrozenUpdateInvalidDenominator', ...
                'Exact frozen source-on update produced an invalid denominator at stage=%s.', stage_tag);
        end
        rho_next_source = rho_minus + (delta ./ c) ./ denom;
        if any(~isfinite(rho_next_source(:)))
            error('realspace_plasma_propagator:ExactFrozenUpdateNonFiniteFinal', ...
                'Exact frozen source-on update produced a non-finite final density at stage=%s.', stage_tag);
        end
        rho_next(source_on_mask) = rho_next_source;
    end

    rho_out = cast(rho_next, 'like', rho_in);
end

function branch_cases = exact_frozen_branch_cases(a, b, c_scalar, rel_tol_like, one_like)
% Classify one frozen rho segment into the closed-form families used below:
% affine when recombination is absent, zero-source when the frozen OFI
% loading term a is effectively off, and source-on when that loading term
% remains active.

    branch_cases = struct( ...
        'affine_problem', (c_scalar == 0), ...
        'small_b_mask', false(size(b)), ...
        'affine_mask', false(size(b)), ...
        'zero_source_mask', false(size(a)), ...
        'source_on_mask', false(size(a)), ...
        'small_b_zero', false(0, 1));
    if branch_cases.affine_problem
        branch_cases.small_b_mask = abs(b) <= rel_tol_like .* max(one_like, abs(b));
        branch_cases.affine_mask = ~branch_cases.small_b_mask;
        return;
    end
    branch_cases.zero_source_mask = abs(a) <= rel_tol_like .* max(one_like, abs(a));
    branch_cases.source_on_mask = ~branch_cases.zero_source_mask;
    if any(branch_cases.zero_source_mask(:))
        b_zero = b(branch_cases.zero_source_mask);
        branch_cases.small_b_zero = abs(b_zero) <= rel_tol_like .* max(one_like, abs(b_zero));
    end
end

function ref_sub = mask_exact_ref_vals_local(ref_vals, mask)
% Return the masked reference vector when exponent diagnostics need it.

    ref_sub = [];
    if ~isempty(ref_vals)
        ref_sub = ref_vals(mask);
    end
end

function [exp_vals, diag_local, plasma_softwarn_state] = exact_update_exp_local( ...
    exp_raw, stage_tag, ref_vals, log_min_2, log_max_2, diag_local, plasma_softwarn_state)
% Guard the exponentials used by the exact frozen closed-form branches.
% If one branch needs exp(...) outside the safe range, hard-fail rather
% than clipping the exponent and silently changing the exact algebra.

    [exp_arg, clamped_exp] = propagation_support.assert_exponent_range(exp_raw, log_min_2, log_max_2);
    if clamped_exp
        ref_min = NaN;
        ref_max = NaN;
        if ~isempty(ref_vals)
            ref_min = min(double(ref_vals(:)));
            ref_max = max(double(ref_vals(:)));
        end
        error('realspace_plasma_propagator:ExactFrozenUpdateExponentOutOfRange', ...
            ['Exact frozen-coefficient plasma update exponent left the valid exp() range at stage=%s. ' ...
             'Observed exponent range=[%.6e, %.6e]; allowed range=[%.6e, %.6e]; ' ...
             'reference range=[%.6e, %.6e]. ' ...
             'Refusing clipped exact-update fallback.'], ...
            stage_tag, min(double(exp_raw(:))), max(double(exp_raw(:))), ...
            double(log_min_2), double(log_max_2), ref_min, ref_max);
    end
    exp_vals = exp(exp_arg);
end

function t_cross = find_exact_frozen_crossing_time_local( ...
    rho_start, rho_target, dt_step, a, b, alpha_recombine, crossing_is_upward)
% Find the within-substep time where one frozen exact segment reaches
% rho_target. The remaining-neutral exact update uses this only when rho
% hits rho_supply and the OFI source law changes, so one plasma substep can
% be split into source-on and source-off pieces and the OFI / avalanche /
% recombination increments stay on the correct side of that boundary.

    n_iter = 48;
    t_lo = zeros(size(rho_start), 'like', rho_start);
    t_hi = cast(dt_step, 'like', rho_start) + zeros(size(rho_start), 'like', rho_start);
    rho_target_like = cast(rho_target, 'like', rho_start);
    diag_stub = struct();
    softwarn_stub = struct();
    for it = 1:n_iter
        t_mid = 0.5 .* (t_lo + t_hi);
        [rho_mid, ~, ~] = apply_exact_frozen_ab_update_local( ...
            rho_start, t_mid, a, b, alpha_recombine, ...
            -Inf, Inf, 'cross', [], diag_stub, softwarn_stub);
        if crossing_is_upward
            hit_mask = (rho_mid >= rho_target_like);
        else
            hit_mask = (rho_mid <= rho_target_like);
        end
        t_hi(hit_mask) = t_mid(hit_mask);
        t_lo(~hit_mask) = t_mid(~hit_mask);
    end
    t_cross = t_hi;
end

%==========================================================================
% IV. File-local helper family: exact frozen ledger reconstruction.
%==========================================================================
function [drho_ofi_step, drho_aval_step, drho_recomb_step, plasma_softwarn_state] = ...
    try_exact_frozen_segment_ledgers_local( ...
    rho_prev, rho_next, dt_step, a, b, w_ofi, w_aval, alpha_recombine, ...
    use_aval, use_recomb, plasma_softwarn_state)
% Recover one exact-frozen mechanism split when possible. If the ledger
% accounting fails after rho_next is already known, keep rho_next and mark
% only the returned mechanism partition invalid for that local segment.

    try
        [drho_ofi_step, drho_aval_step, drho_recomb_step] = ...
            compute_exact_frozen_segment_ledgers_local( ...
                rho_prev, rho_next, dt_step, a, b, w_ofi, w_aval, ...
                alpha_recombine, use_aval, use_recomb);
    catch me_exact_ledger
        drho_ofi_step = nan(size(rho_prev), 'like', rho_prev);
        drho_aval_step = nan(size(rho_prev), 'like', rho_prev);
        drho_recomb_step = nan(size(rho_prev), 'like', rho_prev);
        plasma_softwarn_state = plasma_setup_support.record_exact_ledger_accounting_failed( ...
            plasma_softwarn_state, me_exact_ledger);
    end
end

function [drho_ofi_step, drho_aval_step, drho_recomb_step] = ...
    compute_exact_frozen_source_ledgers_local( ...
    rho_prev, rho_next, dt_step, w_ofi, w_aval, keldysh_context, rho_supply, alpha_recombine, ...
    log_min_2, log_max_2, use_aval, use_recomb)
% Rebuild the exact-frozen OFI / avalanche / recombination split for one
% full plasma step when the exact local stage solve is active and the
% caller asked for per-mechanism ledgers. This replay path is reached
% through exact_avalanche_exp_update_enabled plus
% need_stage_mechanism_ledgers, while use_aval and use_recomb only decide
% which returned ledger channels stay live. The exact stage solve above
% returns only rho_prev -> rho_next, so this helper reruns the same exact
% segment logic with ledger accumulation turned on and verifies that the
% rebuilt rho_next still matches the supplied stage result.

    [rho_rebuilt, drho_ofi_step, drho_aval_step, drho_recomb_step, ~, ~] = ...
        apply_exact_frozen_rho_update_with_ledgers_local( ...
            rho_prev, dt_step, w_ofi, w_aval, keldysh_context, rho_supply, alpha_recombine, ...
            log_min_2, log_max_2, 'exact_ledger_rebuild', [], ...
            use_aval, use_recomb, true, struct(), struct());
    rel_tol = cast(struct_utils.cerupp_numeric_threshold('rel_tol_tight'), 'like', rho_prev);
    mismatch_scale = max(abs(rho_next), abs(rho_rebuilt));
    mismatch_scale = max(mismatch_scale, cast(1, 'like', rho_prev));
    mismatch_mask = abs(rho_rebuilt - rho_next) > (rel_tol .* mismatch_scale);
    if any(mismatch_mask(:))
        error('realspace_plasma_propagator:ExactFrozenBookkeepingRhoMismatch', ...
            ['Exact frozen-coefficient plasma bookkeeping rebuild did not reproduce the ', ...
             'supplied rho_next surface.']);
    end

    if any(~isfinite(drho_ofi_step(:))) || any(~isfinite(drho_aval_step(:))) || any(~isfinite(drho_recomb_step(:)))
        error('realspace_plasma_propagator:ExactFrozenBookkeepingNonFinite', ...
            'Exact frozen-coefficient plasma accounting produced non-finite mechanism increments.');
    end
end

function [drho_ofi_tmp, drho_aval_tmp, drho_recomb_tmp] = ...
    compute_exact_frozen_remaining_neutral_family_local( ...
    rho_prev_sub, rho_next_sub, dt_local, w_ofi_sub, w_aval_sub, ...
    rho_supply_like, alpha_recombine, use_aval, use_recomb, starts_below_supply)
% Rebuild one exact remaining-neutral replay family for entries that all
% start on the same side of rho_supply. starts_below_supply chooses whether
% the family begins on the source-on side (rho < rho_supply) or the
% source-off side (rho >= rho_supply), while use_aval and use_recomb gate
% whether the returned avalanche and recombination ledgers are populated.

    drho_ofi_tmp = zeros(size(rho_prev_sub), 'like', rho_prev_sub);
    drho_aval_tmp = zeros(size(rho_prev_sub), 'like', rho_prev_sub);
    drho_recomb_tmp = zeros(size(rho_prev_sub), 'like', rho_prev_sub);
    source_on_const = w_ofi_sub .* rho_supply_like;
    source_on_gain = w_aval_sub - w_ofi_sub;
    if starts_below_supply
        same_side_mask = (rho_next_sub <= rho_supply_like);
    else
        same_side_mask = (rho_next_sub >= rho_supply_like);
    end

    if any(same_side_mask(:))
        if starts_below_supply
            [drho_ofi_sub, drho_aval_sub, drho_recomb_sub] = compute_exact_frozen_segment_ledgers_local( ...
                rho_prev_sub(same_side_mask), rho_next_sub(same_side_mask), dt_local, ...
                source_on_const(same_side_mask), source_on_gain(same_side_mask), ...
                w_ofi_sub(same_side_mask), w_aval_sub(same_side_mask), ...
                alpha_recombine, use_aval, use_recomb);
        else
            zero_source_same = zeros(sum(same_side_mask(:)), 1, 'like', rho_prev_sub);
            [drho_ofi_sub, drho_aval_sub, drho_recomb_sub] = compute_exact_frozen_segment_ledgers_local( ...
                rho_prev_sub(same_side_mask), rho_next_sub(same_side_mask), dt_local, ...
                zero_source_same, w_aval_sub(same_side_mask), ...
                zero_source_same, w_aval_sub(same_side_mask), ...
                alpha_recombine, use_aval, use_recomb);
        end
        drho_ofi_tmp(same_side_mask) = drho_ofi_sub;
        drho_aval_tmp(same_side_mask) = drho_aval_sub;
        drho_recomb_tmp(same_side_mask) = drho_recomb_sub;
    end

    crossing_mask = ~same_side_mask;
    if ~any(crossing_mask(:))
        return;
    end
    zero_source_cross = zeros(sum(crossing_mask(:)), 1, 'like', rho_prev_sub);
    if starts_below_supply
        t_cross = find_exact_frozen_crossing_time_local( ...
            rho_prev_sub(crossing_mask), rho_supply_like, dt_local, ...
            source_on_const(crossing_mask), source_on_gain(crossing_mask), ...
            alpha_recombine, true);
    else
        t_cross = find_exact_frozen_crossing_time_local( ...
            rho_prev_sub(crossing_mask), rho_supply_like, dt_local, ...
            zero_source_cross, w_aval_sub(crossing_mask), ...
            alpha_recombine, false);
    end
    rho_supply_vec = rho_supply_like + zeros(size(t_cross), 'like', t_cross);
    zero_source_vec = zeros(size(t_cross), 'like', t_cross);
    if starts_below_supply
        [drho_ofi_a, drho_aval_a, drho_recomb_a] = compute_exact_frozen_segment_ledgers_local( ...
            rho_prev_sub(crossing_mask), rho_supply_vec, t_cross, ...
            source_on_const(crossing_mask), source_on_gain(crossing_mask), ...
            w_ofi_sub(crossing_mask), w_aval_sub(crossing_mask), ...
            alpha_recombine, use_aval, use_recomb);
        [drho_ofi_b, drho_aval_b, drho_recomb_b] = compute_exact_frozen_segment_ledgers_local( ...
            rho_supply_vec, rho_next_sub(crossing_mask), dt_local - t_cross, ...
            zero_source_vec, w_aval_sub(crossing_mask), ...
            zero_source_vec, w_aval_sub(crossing_mask), ...
            alpha_recombine, use_aval, use_recomb);
    else
        [drho_ofi_a, drho_aval_a, drho_recomb_a] = compute_exact_frozen_segment_ledgers_local( ...
            rho_prev_sub(crossing_mask), rho_supply_vec, t_cross, ...
            zero_source_vec, w_aval_sub(crossing_mask), ...
            zero_source_vec, w_aval_sub(crossing_mask), ...
            alpha_recombine, use_aval, use_recomb);
        [drho_ofi_b, drho_aval_b, drho_recomb_b] = compute_exact_frozen_segment_ledgers_local( ...
            rho_supply_vec, rho_next_sub(crossing_mask), dt_local - t_cross, ...
            source_on_const(crossing_mask), source_on_gain(crossing_mask), ...
            w_ofi_sub(crossing_mask), w_aval_sub(crossing_mask), ...
            alpha_recombine, use_aval, use_recomb);
    end
    drho_ofi_tmp(crossing_mask) = drho_ofi_a + drho_ofi_b;
    drho_aval_tmp(crossing_mask) = drho_aval_a + drho_aval_b;
    drho_recomb_tmp(crossing_mask) = drho_recomb_a + drho_recomb_b;
end

function [drho_ofi_step, drho_aval_step, drho_recomb_step] = compute_exact_frozen_segment_ledgers_local( ...
    rho_prev, rho_next, dt_step, a, b, w_ofi, w_aval, alpha_recombine, use_aval, use_recomb)
% Recover OFI / avalanche / recombination ledgers for one exact frozen
% segment with
%   d(rho)/dt = rhs_ofi_stage + growth_stage*rho - alpha_recombine*rho.^2.
% In the remaining-neutral source-on branch,
%   rhs_ofi_stage = w_ofi*rho_supply and growth_stage = w_aval - w_ofi;
% in the source-off branch, rhs_ofi_stage = 0 and growth_stage = w_aval.
% The fixed-density exact branch uses the same form with a constant
% rhs_ofi_stage = w_ofi*rho_ofi_scale.

    dt_local = cast(dt_step, 'like', rho_prev);
    c_scalar = double(alpha_recombine);
    c = cast(c_scalar, 'like', rho_prev);
    delta_rho = rho_next - rho_prev;
    rho_int = exact_frozen_rho_time_integral_local( ...
        rho_prev, rho_next, dt_local, a, b, c_scalar, c);
    drho_ofi_step = a .* dt_local - w_ofi .* rho_int;
    drho_aval_step = zeros(size(rho_prev), 'like', rho_prev);
    if use_aval
        drho_aval_step = w_aval .* rho_int;
    end
    drho_recomb_step = zeros(size(rho_prev), 'like', rho_prev);
    if use_recomb
        drho_recomb_step = drho_ofi_step + drho_aval_step - delta_rho;
    end
    [drho_aval_step, drho_recomb_step] = sanitize_exact_frozen_ledgers_local( ...
        drho_aval_step, drho_recomb_step, w_aval .* rho_int, ...
        drho_ofi_step + drho_aval_step - delta_rho, use_aval, use_recomb);
end

function rho_int = exact_frozen_rho_time_integral_local( ...
    rho_prev, rho_next, dt_local, a, b, c_scalar, c)
% Exact rho integral for one frozen local segment used by the exact plasma
% stage solve when exact_avalanche_exp_update_enabled is on. The exact
% frozen ledger recovery uses this integral to rebuild the OFI, avalanche,
% and recombination contributions after rho_next is already known, so this
% is not a plot-only diagnostic helper. It returns
% rho_int = integral_0^dt rho(tau) d tau for one frozen segment and chooses
% among the affine, zero-source, and source-on closed forms without
% rerunning the stage update.

    rel_tol = struct_utils.cerupp_numeric_threshold('rel_tol_tight');
    rel_tol_like = cast(rel_tol, 'like', rho_prev);
    dt_local = cast(dt_local, 'like', rho_prev);
    if isscalar(dt_local)
        dt_local = dt_local + zeros(size(rho_prev), 'like', rho_prev);
    end
    one_like = cast(1, 'like', rho_prev);
    zero_like = cast(0, 'like', rho_prev);
    two_like = cast(2, 'like', rho_prev);
    four_like = cast(4, 'like', rho_prev);
    rho_int = zeros(size(rho_prev), 'like', rho_prev);
    branch_cases = exact_frozen_branch_cases(a, b, c_scalar, rel_tol_like, one_like);
    if branch_cases.affine_problem
        small_b = branch_cases.small_b_mask;
        affine_mask = branch_cases.affine_mask;
        rho_int(small_b) = rho_prev(small_b) .* dt_local(small_b) + ...
            0.5 .* a(small_b) .* (dt_local(small_b) .* dt_local(small_b));
        if any(affine_mask(:))
            b_aff = b(affine_mask);
            rho_int(affine_mask) = (rho_next(affine_mask) - rho_prev(affine_mask) - ...
                a(affine_mask) .* dt_local(affine_mask)) ./ b_aff;
        end
        return;
    end

    % a == 0 means the frozen stage has no OFI source loading, so the
    % accounting integral reduces to the zero-source recombination/gain family.
    % Split the nearly-zero-b limit from the finite-b case so the exact
    % rho(t) integral stays well-conditioned for both pure recombination
    % and growth/decay-with-recombination entries.
    zero_source_mask = branch_cases.zero_source_mask;
    if any(zero_source_mask(:))
        b_zero = b(zero_source_mask);
        rho_zero = rho_prev(zero_source_mask);
        dt_zero = dt_local(zero_source_mask);
        rho_int_zero = zeros(size(rho_zero), 'like', rho_zero);
        small_b_zero = branch_cases.small_b_zero;
        if any(small_b_zero(:))
            rho_int_zero(small_b_zero) = log1p(c .* rho_zero(small_b_zero) .* dt_zero(small_b_zero)) ./ c;
        end
        nonsmall_zero = ~small_b_zero;
        if any(nonsmall_zero(:))
            b_sub = b_zero(nonsmall_zero);
            rho_sub = rho_zero(nonsmall_zero);
            denom_int = one_like + (c .* rho_sub ./ b_sub) .* (exp(b_sub .* dt_zero(nonsmall_zero)) - one_like);
            if any(~isfinite(denom_int(:)) | (denom_int(:) <= 0))
                error('realspace_plasma_propagator:ExactFrozenBookkeepingInvalidIntegral', ...
                    'Exact frozen logistic accounting produced an invalid rho integral denominator.');
            end
            rho_int_zero(nonsmall_zero) = log(denom_int) ./ c;
        end
        rho_int(zero_source_mask) = rho_int_zero;
    end

    % The remaining entries keep OFI source loading, avalanche gain, and
    % recombination active at the same time. Their rho(t) integral comes
    % from the two roots of the source-on quadratic branch, so this branch
    % guards the logarithm denominators explicitly instead of clipping them.
    source_on_mask = branch_cases.source_on_mask;
    if any(source_on_mask(:))
        a_sub = a(source_on_mask);
        b_sub = b(source_on_mask);
        rho_sub = rho_prev(source_on_mask);
        dt_sub = dt_local(source_on_mask);
        delta = sqrt(max(b_sub.^2 + four_like .* c .* a_sub, zero_like));
        rho_plus = (b_sub + delta) ./ (two_like .* c);
        rho_minus = (b_sub - delta) ./ (two_like .* c);
        denom0 = rho_sub - rho_minus;
        scale0 = max(one_like, max(abs(rho_sub), abs(rho_minus)));
        if any(abs(denom0(:)) <= rel_tol_like .* scale0)
            error('realspace_plasma_propagator:ExactFrozenBookkeepingSingularInit', ...
                'Exact frozen source-on accounting encountered a singular initial denominator.');
        end
        q0 = (rho_sub - rho_plus) ./ denom0;
        q1 = q0 .* exp(-delta .* dt_sub);
        denom_q0 = one_like - q0;
        denom_q1 = one_like - q1;
        scale1 = max(one_like, max(abs(q0), abs(q1)));
        if any(abs(denom_q0(:)) <= rel_tol_like .* scale1) || any(abs(denom_q1(:)) <= rel_tol_like .* scale1)
            error('realspace_plasma_propagator:ExactFrozenBookkeepingSingularFinal', ...
                'Exact frozen source-on accounting encountered a singular logarithm denominator.');
        end
        ratio = denom_q1 ./ denom_q0;
        if any(~isfinite(ratio(:)) | (ratio(:) <= 0))
            error('realspace_plasma_propagator:ExactFrozenBookkeepingInvalidIntegral', ...
                'Exact frozen source-on accounting produced a nonpositive rho integral ratio.');
        end
        rho_int(source_on_mask) = rho_plus .* dt_sub + log(ratio) ./ c;
    end
end

function [drho_aval_step, drho_recomb_step] = sanitize_exact_frozen_ledgers_local( ...
    drho_aval_step, drho_recomb_step, aval_ref, recomb_ref, use_aval, use_recomb)
% Clamp only roundoff-level negative avalanche/recombination ledgers to zero.

    like_ref = cast(1, 'like', drho_aval_step);
    neg_tol = 64 .* eps(like_ref);
    if use_aval
        aval_scale = max(like_ref, abs(aval_ref));
        aval_small_neg = isfinite(drho_aval_step) & (drho_aval_step < 0) & ...
            (abs(drho_aval_step) <= neg_tol .* aval_scale);
        drho_aval_step(aval_small_neg) = 0;
        if any(isfinite(drho_aval_step(:)) & (drho_aval_step(:) < 0))
            error('realspace_plasma_propagator:ExactFrozenNegativeAvalancheLedger', ...
                'Exact frozen-coefficient accounting produced a negative avalanche increment beyond roundoff tolerance.');
        end
    end
    if use_recomb
        recomb_scale = max(like_ref, abs(recomb_ref));
        recomb_small_neg = isfinite(drho_recomb_step) & (drho_recomb_step < 0) & ...
            (abs(drho_recomb_step) <= neg_tol .* recomb_scale);
        drho_recomb_step(recomb_small_neg) = 0;
        if any(isfinite(drho_recomb_step(:)) & (drho_recomb_step(:) < 0))
            error('realspace_plasma_propagator:ExactFrozenNegativeRecombLedger', ...
                'Exact frozen-coefficient accounting produced a negative recombination increment beyond roundoff tolerance.');
        end
    end
end

%==========================================================================
% V. File-local helper family: workspace reuse helpers.
%==========================================================================
function [rho_core, stage_workspace] = prepare_plasma_stage_rho_workspace_local( ...
    stage_workspace, like_template, nc, nt)
% Reuse the core-row rho work surface across the current step's plasma stages.

    if ~(isstruct(stage_workspace) && isscalar(stage_workspace))
        error('realspace_plasma_propagator:InvalidStageWorkspace', ...
            ['prepare_plasma_stage_rho_workspace_local requires the caller-owned ', ...
             'stage_workspace scalar struct.']);
    end
    if ~isfield(stage_workspace, 'rho_core')
        rho_core = zeros(nc, nt, 'like', like_template);
    else
        rho_core = stage_workspace.rho_core;
        if ~isnumeric(rho_core) || ~isequal(size(rho_core), [nc, nt]) || ...
                ~strcmp(class(rho_core), class(like_template))
            error('realspace_plasma_propagator:InvalidStageWorkspaceRhoCore', ...
                ['stage_workspace.rho_core must stay shape-matched to the current ', ...
                 'core grid and class once the caller has created it.']);
        end
        rho_core(:) = 0;
    end
    stage_workspace.rho_core = rho_core;
end

function [plasma_book, stage_workspace] = prepare_plasma_stage_book_workspace_local( ...
    stage_workspace, like_template, nc, nt, full_bookkeeping_ledger, emit_mechanism_ledgers)
% Reuse the optional core-row plasma accounting arrays across the current
% step's start/predictor stages when that heavier ledger is enabled.

    if ~(isstruct(stage_workspace) && isscalar(stage_workspace))
        error('realspace_plasma_propagator:InvalidStageWorkspace', ...
            ['prepare_plasma_stage_book_workspace_local requires the caller-owned ', ...
             'stage_workspace scalar struct.']);
    end
    if ~logical(emit_mechanism_ledgers)
        plasma_book = plasma_setup_support.init_plasma_book( ...
            like_template, nc, nt, full_bookkeeping_ledger, emit_mechanism_ledgers);
        stage_workspace.plasma_book = plasma_book;
        return;
    end
    plasma_book = struct();
    if isfield(stage_workspace, 'plasma_book')
        plasma_book = stage_workspace.plasma_book;
    end
    if ~plasma_book_workspace_matches_local(plasma_book, like_template, nc, nt, full_bookkeeping_ledger)
        plasma_book = plasma_setup_support.init_plasma_book( ...
            like_template, nc, nt, full_bookkeeping_ledger, emit_mechanism_ledgers);
    else
        plasma_book.drho_ofi_applied(:) = 0;
        plasma_book.drho_aval_applied(:) = 0;
        plasma_book.exact_valid_core(:) = true;
        if full_bookkeeping_ledger
            plasma_book.drho_recomb_applied(:) = 0;
        end
    end
    stage_workspace.plasma_book = plasma_book;
end

function tf = plasma_book_workspace_matches_local(plasma_book, like_template, nc, nt, full_bookkeeping_ledger)
% Check whether the carried plasma-book arrays can be reused on this stage.

    tf = false;
    if ~isstruct(plasma_book) || ...
            ~isfield(plasma_book, 'drho_ofi_applied') || ...
            ~isfield(plasma_book, 'drho_aval_applied') || ...
            ~isfield(plasma_book, 'exact_valid_core')
        return;
    end
    if ~isequal(size(plasma_book.drho_ofi_applied), [nc, nt]) || ...
            ~isequal(size(plasma_book.drho_aval_applied), [nc, nt]) || ...
            ~isequal(size(plasma_book.exact_valid_core), [nc, nt]) || ...
            ~strcmp(class(plasma_book.drho_ofi_applied), class(like_template)) || ...
            ~strcmp(class(plasma_book.drho_aval_applied), class(like_template))
        return;
    end
    if full_bookkeeping_ledger
        if ~isfield(plasma_book, 'drho_recomb_applied') || ...
                ~isequal(size(plasma_book.drho_recomb_applied), [nc, nt]) || ...
                ~strcmp(class(plasma_book.drho_recomb_applied), class(like_template))
            return;
        end
    elseif isfield(plasma_book, 'drho_recomb_applied')
        return;
    end
    tf = true;
end
