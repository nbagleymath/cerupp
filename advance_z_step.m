function [A_S, A_F, rhs_plasma, rho, A_SSF, step_diag, step_warning_ledgers, step_runtime_meta] = advance_z_step( ...
        A_S, A_F, dz, ...
        mask, mask_f_in, mask_f_w_in, ...
        c, omega_fund, ...
        plasma_step_ctx, nla_step_ctx, ...
        plasma_softwarn_state, nla_softwarn_state, z_curr, ...
        core_idx, ...
        use_nlse_flag, fee_z_rk2_flag, ...
        step_diag_policy, ...
        lin_half_factor_in, guiding_phase_in, guiding_active_in, ...
        advance_step_timing_flag, kerr_n2_xy_in, nla_diag_scatter_ws, ...
        step_custom_args)
%======================================================================%
% ADVANCE_Z_STEP
%======================================================================%
% Advance one outer split-step propagation update for the scalar envelope
% A_S(x,y,t) over one dz. CerUPP threads A_S as the propagated time-domain
% envelope on the omega_ref FFT grid and A_F as the matching full
% spectral-space view, then applies the same split-step order documented
% in cerupp.m:
%   linear half-step -> guiding half-step -> Kerr -> plasma -> NLA ->
%   guiding half-step -> linear half-step -> end-of-step mask/absorber pass.
% On the first propagation call, the launch is masked once before Stage 1.
% cerupp.m drives that with the step-local boolean
% advance_step_builtin.apply_input_closeout_mask = (curr_z_step == 1),
% which is the first-step trigger for that one-time launch mask, so
% propagation starts from the same built launch mask later carried steps
% are meant to obey.
% The linear/guiding/plasma/NLA structure follows the FEE path, while the
% Kerr substep selects either apply_kerr_step_fee(...) for the FEE-form
% frequency-resolved Kerr update or apply_kerr_step_nlse(...) for the
% local real-space phase update via use_nlse_flag. Assumes scalar
% polarization.
% Documentation convention: long-form equations may write A as the manual's
% mathematical envelope symbol, with A ≡ A_S in the code.
%
% User edit guide:
% - If you add a new propagation effect, add it in the step order shown
%   below so the reader can still see where it sits relative to the
%   linear, guiding, Kerr, plasma, and NLA updates. Then thread any new
%   required inputs through this signature explicitly instead of hiding
%   them inside later helpers.
% - cerupp.m passes one major_step_custom_args struct into this helper.
%   Built-in substeps peel their kerr/plasma/nla buckets locally, and any
%   other top-level buckets remain available here for direct
%   advance_z_step(...) logic.
% - calculate_medium_properties_z(...) rebuilds medium/operator state
%   before this helper is called; it does not add implicit per-step
%   physics inputs through this signature.
% - The plasma bucket may include nested plasma.evolve_rho_td and
%   plasma.keldysh structs for the deeper plasma helpers.
% - The warning ledgers, optional plasma workspace, and optional NLA
%   diagnostic scatter workspace are the mutable carryover surfaces
%   threaded through this step call. A_S and A_F are the driver-owned
%   field state, while rhs_plasma, rho, and the step diagnostics are
%   step-owned outputs.
%
% STEP ORDER (Split-step outer sequence):
% 1) linear half-step in (kx,ky,omega)
% 2) guiding half-step in (x,y,omega)
% 3) Kerr
% 4) plasma
% 5) NLA/MPA
% 6) guiding half-step
% 7) linear half-step
% 8) binary k and omega mask cleanup, real-space absorber, and final
%    binary k and omega cleanup on the returned state
%
% KEY CONVENTIONS:
% - Linear half-step multiplies by the caller-built factor
%   lin_half_factor_in for the current dz. cerupp.m decides whether that
%   factor was reused from the last same-dz step or rebuilt for this one.
% - Guiding half-step multiplies by the caller-built phase factor
%   guiding_phase_in = exp(+1i * guiding_matrix * (dz/2)).
%   cerupp.m decides whether that factor was reused or rebuilt, and
%   guiding_active_in marks whether the current guiding half-step factor
%   differs from unity, so this step can skip that multiply when false.
% - NLA/MPA is applied through the intensity loss law first and then
%   mapped back onto the complex envelope. In amplitude notation
%       dA/dz|_NLA = -S_NLA,time,   I = |A|^2.
%   Here S_NLA,time is the amplitude-level sink associated with the
%   selected intensity law. CerUPP applies that sink by evolving I over dz
%   and then rescaling
%       A <- A .* sqrt(I_new./I_old),
%   so the NLA substep removes amplitude while preserving phase.
%   Applied propagation law:
%   - Static beta_K closure applies either the analytic single-order update
%     or the summed multi-order Euler/midpoint update over dz, then applies
%     field rescaling A <- A .* sqrt(I_new./I_old).
%   - OFI-based NLA keeps the same active plasma OFI rate law
%     as the source step, written here as W_ion(I): the runtime Keldysh
%     lookup when enabled, or the static sum_K sigma_K I^K law otherwise.
%     In amplitude notation that means
%       S_NLA,time = 0.5 * Udep_matched * density_scale * (W_ion(I)./I) .* A,
%     where density_scale is whichever OFI weighting branch is active and
%     Udep_matched is the setup-side optical depletion energy assigned to
%     each OFI event in the matched sink.
%     The scalar matched-depletion form below covers the dynamic branch and
%     the static sum_K sigma_K I^K branch. It applies
%       dI/dz = -Udep_matched * rho_ofi_scale * W_ion(I),
%         rho_ofi_scale from the fixed-density-scale OFI setup
%     or
%       dI/dz = -Udep_matched * max(rho_supply-rho,0) * W_ion(I).
%     Choosing Udep_matched = K*hbar*omega_fund reproduces the usual
%     single-K MPI loss.
%   Analysis-only diagnostics:
%   - sigma_K,eff and beta_eff_* are reported for analysis only; they do
%     not replace the applied matched loss law.
%   - Dynamic W_ion(I) is the same runtime Keldysh rate law that
%     cerupp.m built in Section 2E from the selected material inputs and
%     then passed into this step.
%     K_display only feeds the derived sigma_K,eff / beta_eff_* diagnostic
%     remap, while the static sum_K sigma_K I^K branch uses its local
%     log-slope K_eff(I)=d ln(W_ion)/d ln(I).
%   - beta_eff_full stays referenced to
%     Udep_matched * rho_nt_keldysh_norm_m3 * sigma_eff, so cap-limited
%     runs still keep the full-neutral Keldysh-normalization reference
%     used by the matched-law setup.
%   - beta_eff_applied tracks the actual matched-loss coefficient on that
%     step:
%     Udep_matched * remaining_neutral * sigma_eff for remaining-neutral
%     runs, or Udep_matched * rho_ofi_scale * sigma_eff for the fixed
%     cap-aware density-scale branch.
%   Optional neutral-fraction modifier:
%   - The user-facing replenishment knobs are
%     plasma_ofi_use_remaining_neutral_factor_flag and
%     nla_use_remaining_neutral_factor_flag.
%   - Under static_mpi_beta, the applied static sink is scaled by
%     clamp((rho_supply-rho)/rho_nt,0,1) only when the selected static
%     closure uses remaining-neutral weighting, and stays on the baseline
%     local beta_K sink otherwise. By default rho_supply=rho_nt; with a
%     source-side reservoir override it follows
%     plasma_runtime_cfg.neutral_reservoir_m3.
%   - Under plasma_ofi, the plasma OFI source and the OFI-based optical
%     sink may read the same reservoir state, but the two weighting flags
%     stay independent. Setup warns when they disagree, and the selected
%     NLA closure can therefore keep fixed rho_ofi_scale weighting even
%     when the plasma source uses remaining-neutral weighting.
%
% STEP INTERFACE:
% - Inputs follow the positional signature above.
% - State/position: A_S, A_F, dz, z_curr.
% - Linear/guiding operator state: lin_half_factor_in and guiding_phase_in
%   are the current-step factors on entry. guiding_active_in marks whether
%   the current guiding half-step factor differs from unity, so this step
%   can skip that multiply when false. If dz or the medium changed,
%   cerupp.m already rebuilt the factors before calling this helper. mask
%   is the current-step real-space mask applied on the launch-plane entry
%   mask pass and on the end-of-step absorber pass.
% - mask_f_in and mask_f_w_in are the transverse-k and omega masks for
%   this step. Nonzero means admitted; zero means rejected.
% - Before a later nonlinear stage or the return guiding half-step reads
%   the field, the binary runtime gate keeps every admitted bin and zeros
%   only the fully rejected bins.
% - The final end-of-step mask pass applies the real-space absorber and
%   returns the carried state after that same binary k and omega
%   admit/reject cleanup used during the step.
% - plasma_step_ctx and nla_step_ctx are the already-selected current-step
%   plasma/NLA inputs from cerupp.m. The propagation loop picks them from
%   the prebuilt store/checkpoint variants before calling this helper.
% - Returns the updated field state directly plus compact step-local
%   diagnostic, warning-state, and timing structs.
% - Plasma-disabled paths keep rhs_plasma and rho empty.
%
% FILE-LOCAL MINI SECTION MAP:
% 1) linear half-step in (kx,ky,omega)
% 2) guiding half-step in (x,y,omega)
% 3) Kerr
% 4) plasma
% 5) NLA/MPA
% 6) guiding half-step in (x,y,omega)
% 7) linear half-step in (kx,ky,omega)
% 8) binary k and omega admit/reject cleanup plus the real-space mask on
%    the returned state. The late-file helpers supply the
%    Kerr/plasma/NLA utilities, finite-state checks, and timing/validation
%    support behind those numbered stages.


%======================================================================%
% I. File-local entry contract and propagation-loop unpacking.
% Step-owned outputs that only appear on selected branches start empty.
step_runtime_meta = [];
plasma_stiffness_diagnostic_step = [];
sigma_k_eff_keldysh = [];
beta_eff_full_keldysh = [];
beta_eff_applied_keldysh = [];
keldysh_diag_i_core = [];
keldysh_diag_rho_core = [];
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Settle the current-step state once at entry:
% unpack the selected runtime surfaces, then let the rest of the routine
% focus on the split-step physics. step_custom_args stays available for
% any direct hook logic added in this step owner.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

timing_flag = advance_step_timing_flag;
if ~(isstruct(step_custom_args) && isscalar(step_custom_args))
    error('CerUPP:InvalidAdvanceStepCustomArgs', ...
        'step_custom_args must be a scalar struct when supplied to advance_z_step(...).');
end
kerr_custom_args = unpack_step_custom_bucket_local(step_custom_args, 'kerr');
plasma_custom_args = unpack_step_custom_bucket_local(step_custom_args, 'plasma');
nla_custom_args = unpack_step_custom_bucket_local(step_custom_args, 'nla');
advance_step_builtin_custom_args = unpack_step_custom_bucket_local( ...
    step_custom_args, 'advance_step_builtin');
if ~isempty(A_S)
    [nx, ny, nt] = size(A_S);
else
    [nx, ny, nt] = size(A_F);
end
[kerr_enabled, kerr_n2_xy, kerr_n2_core, kerr_fee_qomega_payload] = ...
    propagation_support.unpack_kerr_step_payload_local(kerr_n2_xy_in, use_nlse_flag);
emit_full_nla_maps = step_diag_policy.emit_full_nla_maps;
if emit_full_nla_maps
    nla_diag_scatter_ws = propagation_support.normalize_nla_diag_scatter_workspace_local( ...
        nla_diag_scatter_ws, core_idx);
end
propagation_support.assert_mask_shape_fast(mask, nx, ny, 'mask');
assert_step_operator_shape_local(lin_half_factor_in, [nx, ny, nt], 'lin_half_factor_in');
if logical(guiding_active_in) || ~isempty(guiding_phase_in)
    assert_step_operator_shape_local(guiding_phase_in, [nx, ny, nt], 'guiding_phase_in');
end
detect_blowup_cause_flag = step_diag_policy.need_stage_finite_scan;
step_runtime_meta = struct( ...
    'timing_enabled', timing_flag, ...
    'timing', struct(), ...
    'plasma_stage_workspace', struct());
if timing_flag
    step_runtime_meta.timing = propagation_support.zero_runtime_checkpoint_stage_struct_local();
end
t_total = start_stage_timer_local(timing_flag);
need_intens_s = step_diag_policy.need_intens_s;
need_kerr_delta = step_diag_policy.need_kerr_delta;
need_return_a_s = step_diag_policy.need_return_a_s;
need_return_a_ssf = step_diag_policy.need_return_a_ssf;
apply_input_closeout_mask = logical(struct_utils.opt_struct_field( ...
    advance_step_builtin_custom_args, 'apply_input_closeout_mask', false, ...
    'treat_empty_as_missing', true));
if apply_input_closeout_mask
    % Keep the first propagated launch on the same built mask later steps
    % are meant to carry, including the real-space absorber.
    [A_F, a_s_entry_masked] = propagation_support.apply_runtime_launch_mask_local( ...
        A_F, mask_f_in, mask_f_w_in, mask, ~isempty(A_S));
    if ~isempty(A_S)
        A_S = a_s_entry_masked;
    end
    if detect_blowup_cause_flag
        if ~isempty(A_S)
            propagation_support.assert_finite_step_state( ...
                A_S, 'A_S', 'post_launch_mask_entry', z_curr);
        end
        propagation_support.assert_finite_step_state( ...
            A_F, 'A_F', 'post_launch_mask_entry', z_curr);
    end
end
emit_keldysh_effective_nla_diag_payloads = ...
    step_diag_policy.emit_keldysh_effective_nla_diag_payloads;
keldysh_effective_diag_axis_in_core = ...
    step_diag_policy.keldysh_effective_diag_axis_in_core;
keldysh_effective_diag_axis_core_row = ...
    step_diag_policy.keldysh_effective_diag_axis_core_row;
intens_s = [];
d_a_kerr = [];
j_mpa = [];
mpa_rhs_mag = [];
nla_book = [];
plasma_book = [];
rhs_plasma = [];
rho = [];
rho_finite_scan = [];
rho_core_for_nla = [];
post_step_peak_rho = NaN;
A_S = [];
A_SSF = [];
plasma_flag = plasma_step_ctx.plasma_flag;
nl_absorption_flag = nla_step_ctx.nl_absorption_flag;

%------------------------------------------------------------------%
% 1) Linear half-step in (kx,ky,omega).
%    Apply the caller-supplied current-step diffraction/dispersion factor.
%    Any same-dz cache reuse or dz-triggered rebuild was already settled in
%    cerupp.m before this step started.
%------------------------------------------------------------------%
tblk = start_stage_timer_local(timing_flag);
lin_half_factor = lin_half_factor_in;
A_F = A_F .* lin_half_factor;
step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'lin1', tblk);
if detect_blowup_cause_flag
    propagation_support.assert_finite_step_state(A_F, 'A_F', 'post_lin1', z_curr);
end

%------------------------------------------------------------------%
% 2) Guiding half-step in (x,y,omega).
%    Convert A_F -> A_SSF and apply the first guiding half-step when
%    guiding is active.
%------------------------------------------------------------------%
tblk = start_stage_timer_local(timing_flag);
guiding_phase = guiding_phase_in;
guiding_active = logical(guiding_active_in);
nonlinear_free_fastpath = ~kerr_enabled && ~plasma_flag && ~nl_absorption_flag;
if nonlinear_free_fastpath
    a_ssf_linear = ifft2(A_F);
    if guiding_active
        a_ssf_linear = a_ssf_linear .* guiding_phase;
        if ~isempty(mask_f_in) || ~isempty(mask_f_w_in)
            % Before the second guiding half-step, keep only the admitted
            % nonzero support so the linear-only fast path stays on the
            % same runtime admit/reject rule as the carried field.
            A_F = project_supported_spectral_bins_local( ...
                fft2(a_ssf_linear), mask_f_in, mask_f_w_in);
            a_ssf_linear = ifft2(A_F);
        end
    end
    if detect_blowup_cause_flag
        propagation_support.assert_finite_step_state(a_ssf_linear, 'A_SSF', 'post_guiding', z_curr);
    end
    if need_intens_s
        A_S_linear = ifft(a_ssf_linear, [], 3);
        intens_s = real(A_S_linear .* conj(A_S_linear));
    end
    % If there is no Kerr/plasma/NLA work on this step, keep the state in
    % mixed space and apply the return guiding half-step here instead of
    % paying for the nonlinear branch's flattened time-domain
    % gather/scatter setup.
    if guiding_active
        a_ssf_linear = a_ssf_linear .* guiding_phase;
        if ~isempty(mask_f_in) || ~isempty(mask_f_w_in)
            A_F = project_supported_spectral_bins_local( ...
                fft2(a_ssf_linear), mask_f_in, mask_f_w_in);
            a_ssf_linear = ifft2(A_F);
        end
    end
    step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'guiding_total', tblk);

    % Keep nonlinear-free steps in spectral/mixed space until the shared
    % final end-of-step mask pass. That skips the unused nonlinear-state
    % round-trip before the final A_S/A_F state is rebuilt.
    tblk = start_stage_timer_local(timing_flag);
    [A_S, A_F, A_SSF] = finish_step_closeout_local( ...
        a_ssf_linear, lin_half_factor, mask_f_in, mask, ...
        mask_f_w_in, ...
        need_return_a_s, need_return_a_ssf);
    if detect_blowup_cause_flag
        if need_return_a_s
            propagation_support.assert_finite_step_state(A_S, 'A_S', 'post_linear_closeout', z_curr);
        end
        propagation_support.assert_finite_step_state(A_F, 'A_F', 'post_linear_closeout', z_curr);
        if need_return_a_ssf
            propagation_support.assert_finite_step_state(A_SSF, 'A_SSF', 'post_linear_closeout', z_curr);
        end
    end
    step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'linear_tail_plus_absorber', tblk);
else
    % Before Kerr/plasma/NLA start, apply the binary runtime mask rule:
    % keep every nonzero admitted (kx,ky,omega) bin and zero only the
    % fully rejected bins.
    A_F = project_supported_spectral_bins_local(A_F, mask_f_in, mask_f_w_in);
    if detect_blowup_cause_flag
        propagation_support.assert_finite_step_state( ...
            A_F, 'A_F', 'post_pre_nonlinear_support_project', z_curr);
    end
    a_ssf_nonlinear = ifft2(A_F);
    if guiding_active
        a_ssf_nonlinear = a_ssf_nonlinear .* guiding_phase;
        if ~isempty(mask_f_in) || ~isempty(mask_f_w_in)
            % The mixed-space guiding multiply is not diagonal in
            % transverse-k, so rebuild A_F and reapply the same binary
            % admit/reject gate before Kerr reads the guided field.
            A_F = project_supported_spectral_bins_local( ...
                fft2(a_ssf_nonlinear), mask_f_in, mask_f_w_in);
            a_ssf_nonlinear = ifft2(A_F);
        end
    end
    if detect_blowup_cause_flag
        propagation_support.assert_finite_step_state(a_ssf_nonlinear, 'A_SSF', 'post_guiding', z_curr);
    end
    a_nonlinear_2_d = reshape(ifft(a_ssf_nonlinear, [], 3), nx * ny, nt);
    a_ssf_nonlinear = [];
    step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'guiding_total', tblk);

    % Carry one flattened field plus its active core rows through the
    % nonlinear chain so Kerr/plasma/NLA do not keep rebuilding the same
    % gather/scatter view.
    a_core_nonlinear = a_nonlinear_2_d(core_idx, :);

    %------------------------------------------------------------------%
    % 3) Kerr substep in real space.
    %------------------------------------------------------------------%
    % use_nlse_flag = true:
    %   instantaneous local phase update
    %   A_S <- A_S .* exp(+1i * phi),  phi = (omega_fund/c) * n2(x,y) * |A_S|^2 * dz.
    % use_nlse_flag = false:
    %   FEE-form Kerr step for
    %   dA/dz = i * IFFT_t{ Q(omega) .* FFT_t{ n2(x,y) * |A|^2 * A } },
    %   Q(omega) = (omega/c) * n_sell(omega_fund) / n_sell(omega).
    %   The setup-built fee_qomega_payload.qomega_w bundle carries that
    %   frequency-only prefactor on the solver omega grid, and the source
    %   is then advanced with Euler or RK2 in z before it is scattered
    %   back onto the full field.
    if detect_blowup_cause_flag
        if kerr_enabled
            post_kerr_stage_label = 'post_kerr';
        else
            if plasma_flag
                post_kerr_stage_label = 'state_before_plasma';
            else
                post_kerr_stage_label = 'state_before_nla';
            end
        end
        if plasma_flag
            pre_plasma_stage_label = 'pre_plasma';
            post_plasma_stage_label = 'post_plasma';
        else
            pre_plasma_stage_label = 'state_before_nla';
            post_plasma_stage_label = 'state_before_nla';
        end
        a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
        propagation_support.assert_finite_step_state(a_s_check, 'A_S', 'post_time_reconstruct', z_curr);
    end
    tblk = start_stage_timer_local(timing_flag);
    % Only build the full-grid post-Kerr intensity when a downstream diagnostic
    % actually uses it. The driver can rebuild any code-metric intensity it
    % needs later from A_S itself.

    % Apply the selected Kerr update and return only the post-Kerr surfaces
    % that later stages or diagnostics actually asked for on this step.

    [a_nonlinear_2_d, intens_s, d_a_kerr, a_core_nonlinear] = apply_kerr_step_selected_local( ...
        a_nonlinear_2_d, a_core_nonlinear, nx, ny, ...
        kerr_enabled, use_nlse_flag, need_intens_s, need_kerr_delta, ...
        kerr_n2_xy, omega_fund, c, dz, kerr_fee_qomega_payload, core_idx, ...
        kerr_n2_core, fee_z_rk2_flag, kerr_custom_args);
    step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'kerr', tblk);
    % Keep the optional finite-state scan pinned to the post-Kerr surfaces so a
    % Kerr-stage blowup is reported before later substeps overwrite the evidence.

    if detect_blowup_cause_flag
        a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
        propagation_support.assert_finite_step_state( ...
            a_s_check, 'A_S', post_kerr_stage_label, z_curr);
        propagation_support.assert_finite_step_state( ...
            intens_s, 'Intens_s', post_kerr_stage_label, z_curr);
    end
    if kerr_enabled && (~isempty(mask_f_in) || ~isempty(mask_f_w_in)) && ...
            (plasma_flag || nl_absorption_flag || ~guiding_active)
        if plasma_flag || nl_absorption_flag
            % Before plasma or NLA reads the field, keep only the admitted
            % k and omega bins.
            post_kerr_project_label = 'post_kerr_guard_project';
        else
            % If Kerr is the last spectral-mixing stage before closeout,
            % keep only the admitted k and omega bins before the linear
            % tail and absorber pass.
            post_kerr_project_label = 'post_kerr_closeout_project';
        end
        [a_nonlinear_2_d, A_F] = ...
            project_time_rows_onto_supported_spectral_bins_local( ...
                a_nonlinear_2_d, nx, ny, mask_f_in, mask_f_w_in);
        a_core_nonlinear = a_nonlinear_2_d(core_idx, :);
        if detect_blowup_cause_flag
            a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
            propagation_support.assert_finite_step_state( ...
                a_s_check, 'A_S', post_kerr_project_label, z_curr);
        end
    end

    %------------------------------------------------------------------%
    % 4) Plasma substep.
    %    The actual plasma physics enters through realspace_plasma_propagator.
    %------------------------------------------------------------------%
    if detect_blowup_cause_flag
        a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
        propagation_support.assert_finite_step_state( ...
            a_s_check, 'A_S', pre_plasma_stage_label, z_curr);
    end
    tblk = start_stage_timer_local(timing_flag);
    if plasma_flag
        % Main plasma physics call for this z step: apply the plasma update and
        % return both the field increment and the density view that downstream
        % NLA accounting may reuse.

        [a_nonlinear_2_d, a_core_nonlinear, rhs_plasma, rho, ...
         rho_core_for_nla, rho_finite_scan, post_step_peak_rho, ...
         plasma_stiffness_diagnostic_step, plasma_softwarn_state, ...
         plasma_book, plasma_stage_workspace] = apply_plasma_step( ...
            a_nonlinear_2_d, a_core_nonlinear, nx, ny, dz, z_curr, ...
            plasma_step_ctx, plasma_softwarn_state, plasma_custom_args, ...
            detect_blowup_cause_flag);
        step_runtime_meta.plasma_stage_workspace = plasma_stage_workspace;
    else
        plasma_stiffness_diagnostic_step = [];
        plasma_book = [];
    end
    step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'plasma', tblk);
    if detect_blowup_cause_flag
        a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
        propagation_support.assert_finite_step_state( ...
            a_s_check, 'A_S', post_plasma_stage_label, z_curr);
        propagation_support.assert_finite_step_state( ...
            rhs_plasma, 'rhs_plasma', post_plasma_stage_label, z_curr);
        propagation_support.assert_finite_step_state( ...
            rho_finite_scan, 'rho', post_plasma_stage_label, z_curr);
    end
    if plasma_flag && (~isempty(mask_f_in) || ~isempty(mask_f_w_in)) && ...
            (nl_absorption_flag || ~guiding_active)
        if nl_absorption_flag
            % Plasma can also broaden the field outside the current
            % passband, so remove only the fully rejected bins before NLA
            % reads it.
            post_plasma_project_label = 'post_plasma_guard_project';
        else
            % If plasma is the last spectral-mixing stage before closeout,
            % keep only the admitted k and omega bins before the linear
            % tail and absorber pass.
            post_plasma_project_label = 'post_plasma_closeout_project';
        end
        [a_nonlinear_2_d, A_F] = ...
            project_time_rows_onto_supported_spectral_bins_local( ...
                a_nonlinear_2_d, nx, ny, mask_f_in, mask_f_w_in);
        a_core_nonlinear = a_nonlinear_2_d(core_idx, :);
        if detect_blowup_cause_flag
            a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
            propagation_support.assert_finite_step_state( ...
                a_s_check, 'A_S', post_plasma_project_label, z_curr);
        end
    end

    %------------------------------------------------------------------%
    % 5) Nonlinear absorption (MPA/NLA).
    %    Apply the chosen depletion law, then emit only the diagnostic shapes
    %    the driver asked this step to keep.
    %------------------------------------------------------------------%
    tblk = start_stage_timer_local(timing_flag);
    emit_mpa_full_grids = nla_step_ctx.emit_mpa_full_grids;
    need_mpa_rhs_core = nla_step_ctx.need_mpa_rhs_core;
    if nl_absorption_flag
        if need_mpa_rhs_core
            a_core_before_nla = a_core_nonlinear;
        else
            a_core_before_nla = [];
        end
        % Main NLA physics call for this z step: apply the chosen loss law and
        % return the core-only diagnostics/accounting data that the driver may
        % reduce or scatter after the field update is done.

        [a_nonlinear_2_d, a_core_nonlinear, j_mpa_core, ...
         nla_diag_core, nla_softwarn_state, nla_book] = apply_nla_step( ...
            a_nonlinear_2_d, a_core_nonlinear, rho_core_for_nla, ...
            nx, ny, dz, nla_step_ctx, nla_softwarn_state, nla_custom_args);
        % The NLA helper also returns the updated core rows, so later
        % diagnostics do not need to regather the post-NLA core state from
        % the full field.

        nt_nla = size(a_nonlinear_2_d, 2);
        scatter_like = real(a_nonlinear_2_d(1));
        % Optional NLA envelope-loss diagnostic:
        % j_mpa_core is the pre-step model coefficient returned by the
        % selected NLA closure, while
        %   mpa_rhs_mag = |A_after - A_before| / dz
        % is the step-average attenuation magnitude inferred from the
        % completed-step envelope update.

        if need_mpa_rhs_core
            dz_real_like = cast(double(real(dz)), 'like', real(a_core_before_nla));
            mpa_rhs_mag_core = abs(a_core_before_nla - a_core_nonlinear) ./ dz_real_like;
        else
            mpa_rhs_mag_core = [];
        end
        % Scatter optional NLA diagnostics out to full-grid form only when the
        % driver asked for them; otherwise keep the core-only quantities local.

        [j_mpa, nla_diag_scatter_ws] = propagation_support.emit_nla_diag_output_local( ...
            j_mpa_core, emit_mpa_full_grids, emit_full_nla_maps, ...
            core_idx, nx, ny, nt_nla, scatter_like, nla_diag_scatter_ws, false);
        [mpa_rhs_mag, nla_diag_scatter_ws] = propagation_support.emit_nla_diag_output_local( ...
            mpa_rhs_mag_core, need_mpa_rhs_core, emit_full_nla_maps, ...
            core_idx, nx, ny, nt_nla, scatter_like, nla_diag_scatter_ws, true);
        % The driver also stores the raw core intensity/rho slices behind
        % the on-axis and max-perpendicular OFI-based NLA traces, so those
        % traces can be rebuilt later if the plotted scalar exponent is
        % chosen from the achieved run-global peak intensity.

        sigma_k_eff_keldysh = propagation_support.summarize_keldysh_effective_diag_core_local( ...
            nla_diag_core.sigma_k_eff, emit_keldysh_effective_nla_diag_payloads, ...
            keldysh_effective_diag_axis_in_core, ...
            keldysh_effective_diag_axis_core_row);
        beta_eff_full_keldysh = propagation_support.summarize_keldysh_effective_diag_core_local( ...
            nla_diag_core.beta_eff_full, emit_keldysh_effective_nla_diag_payloads, ...
            keldysh_effective_diag_axis_in_core, ...
            keldysh_effective_diag_axis_core_row);
        beta_eff_applied_keldysh = propagation_support.summarize_keldysh_effective_diag_core_local( ...
            nla_diag_core.beta_eff_applied, emit_keldysh_effective_nla_diag_payloads, ...
            keldysh_effective_diag_axis_in_core, ...
            keldysh_effective_diag_axis_core_row);
        if emit_keldysh_effective_nla_diag_payloads
            keldysh_diag_i_core = nla_diag_core.i_eval;
            keldysh_diag_rho_core = nla_diag_core.rho_core;
        end
    else
        sigma_k_eff_keldysh = [];
        beta_eff_full_keldysh = [];
        beta_eff_applied_keldysh = [];
        keldysh_diag_i_core = [];
        keldysh_diag_rho_core = [];
        nla_book = [];
    end
    step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'nla', tblk);
    if detect_blowup_cause_flag
        a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
        propagation_support.assert_finite_step_state(a_s_check, 'A_S', 'post_nla', z_curr);
    end
    if guiding_active && (~isempty(mask_f_in) || ~isempty(mask_f_w_in))
        % Before the return guiding half-step, keep fully rejected bins
        % out before guiding reads the field again.
        [a_nonlinear_2_d, A_F] = ...
            project_time_rows_onto_supported_spectral_bins_local( ...
                a_nonlinear_2_d, nx, ny, mask_f_in, mask_f_w_in);
        a_core_nonlinear = a_nonlinear_2_d(core_idx, :);
        if detect_blowup_cause_flag
            a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
            propagation_support.assert_finite_step_state( ...
                a_s_check, 'A_S', 'pre_guiding_return_support_project', z_curr);
        end
    elseif nl_absorption_flag && (~isempty(mask_f_in) || ~isempty(mask_f_w_in))
        % If NLA is the last spectral-mixing stage before closeout, keep
        % only the admitted k and omega bins before the linear tail and
        % absorber pass.
        [a_nonlinear_2_d, A_F] = ...
            project_time_rows_onto_supported_spectral_bins_local( ...
                a_nonlinear_2_d, nx, ny, mask_f_in, mask_f_w_in);
        a_core_nonlinear = a_nonlinear_2_d(core_idx, :);
        if detect_blowup_cause_flag
            a_s_check = reshape(a_nonlinear_2_d, nx, ny, nt);
            propagation_support.assert_finite_step_state( ...
                a_s_check, 'A_S', 'post_nla_closeout_project', z_curr);
        end
    end

    %------------------------------------------------------------------%
    % 6) Guiding return half-step in (x,y,omega).
    %------------------------------------------------------------------%
    tblk = start_stage_timer_local(timing_flag);
    % Reuse mixed-space representation directly: A_SSF = F_t{A_S}.
    % Do not IFFT back to time here; the final linear half-step consumes A_SSF.

    A_SSF = reshape(fft(a_nonlinear_2_d, [], 2), nx, ny, nt);
    if guiding_active
        A_SSF = A_SSF .* guiding_phase;
        if ~isempty(mask_f_in) || ~isempty(mask_f_w_in)
            A_F = project_supported_spectral_bins_local( ...
                fft2(A_SSF), mask_f_in, mask_f_w_in);
            A_SSF = ifft2(A_F);
        end
    end
    step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'guiding_total', tblk);
    if detect_blowup_cause_flag
        propagation_support.assert_finite_step_state(A_SSF, 'A_SSF', 'post_guiding_return', z_curr);
    end

    %------------------------------------------------------------------%
    % 7) Final linear half-step and end-of-step masking.
    %    Reuse the shared end-of-step helper so the final linear half-step,
    %    real-space absorber, and carried-state admit/reject rebuild stay
    %    in one place after the earlier binary mask-rule checks.
    %------------------------------------------------------------------%
    tblk = start_stage_timer_local(timing_flag);
    [A_S, A_F, A_SSF] = finish_step_closeout_local( ...
        A_SSF, lin_half_factor, mask_f_in, mask, ...
        mask_f_w_in, ...
        need_return_a_s, need_return_a_ssf);
    if detect_blowup_cause_flag
        if need_return_a_s
            propagation_support.assert_finite_step_state(A_S, 'A_S', 'post_linear_closeout', z_curr);
        end
        propagation_support.assert_finite_step_state(A_F, 'A_F', 'post_linear_closeout', z_curr);
        if need_return_a_ssf
            propagation_support.assert_finite_step_state(A_SSF, 'A_SSF', 'post_linear_closeout', z_curr);
        end
    end
    step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'linear_tail_plus_absorber', tblk);
end


% DETECT CRASHED AND IDENTIFY THEIR CAUSE IF detect_blowup_cause_flag is true
post_step_peak_abs = NaN;
if need_return_a_s
    post_step_peak_abs = propagation_support.assert_finite_step_state(A_S, 'A_S', 'end_step', z_curr);
end
post_step_peak_intensity = NaN;
if isfinite(post_step_peak_abs)
    post_step_peak_intensity = double(post_step_peak_abs) * double(post_step_peak_abs);
end
if detect_blowup_cause_flag
    propagation_support.assert_finite_step_state(A_F, 'A_F', 'end_step', z_curr);
    propagation_support.assert_finite_step_state(rhs_plasma, 'rhs_plasma', 'end_step', z_curr);
    propagation_support.assert_finite_step_state(rho_finite_scan, 'rho', 'end_step', z_curr);
end

if need_intens_s
    if need_return_a_s
        intens_s = real(A_S .* conj(A_S));
    else
        intens_s = [];
    end
end

step_runtime_meta = finish_stage_timer_local(step_runtime_meta, 'total', t_total);

% Final outward packaging for the driver:
% - step_runtime_meta keeps the sampled substep timings,
% - step_diag keeps the step-owned diagnostic surfaces, and
% - step_warning_ledgers carries the updated plasma/NLA warning ledgers.
step_diag = struct( ...
    'intens_s', intens_s, ...
    'd_a_kerr', d_a_kerr, ...
    'j_mpa', j_mpa, ...
    'sigma_k_eff_keldysh', sigma_k_eff_keldysh, ...
    'beta_eff_full_keldysh', beta_eff_full_keldysh, ...
    'beta_eff_applied_keldysh', beta_eff_applied_keldysh, ...
    'keldysh_diag_i_core', keldysh_diag_i_core, ...
    'keldysh_diag_rho_core', keldysh_diag_rho_core, ...
    'nla_book', nla_book, ...
    'plasma_book', plasma_book, ...
    'nla_diag_scatter_ws', nla_diag_scatter_ws, ...
    'mpa_rhs_mag', mpa_rhs_mag, ...
    'plasma_stiffness_diagnostic', plasma_stiffness_diagnostic_step, ...
    'post_step_peak_rho', post_step_peak_rho, ...
    'post_step_peak_intensity', post_step_peak_intensity);
step_warning_ledgers = struct( ...
    'plasma', plasma_softwarn_state, ...
    'nla', nla_softwarn_state);

end

function bucket_value = unpack_step_custom_bucket_local(step_custom_args, bucket_name)
% Return one optional built-in step-custom bucket as a scalar struct.

    bucket_value = struct();
    if isfield(step_custom_args, bucket_name) && ...
            ~isempty(step_custom_args.(bucket_name))
        bucket_value = step_custom_args.(bucket_name);
    end
    if ~isstruct(bucket_value) || ~isscalar(bucket_value)
        error('CerUPP:AdvanceStepInvalidMajorStepCustomArgField', ...
            'major_step_custom_args.%s must be a scalar struct when supplied.', ...
            bucket_name);
    end
end

%==========================================================================
% IV. File-local helper family: Kerr substeps.
%==========================================================================
function [A_S, intens_s, d_a_kerr, A_core_after_kerr] = apply_kerr_step_selected_local( ...
    A_S, A_core_in, nx, ny, kerr_enabled, use_nlse_flag, need_intens_s, need_kerr_delta, ...
    kerr_n2_xy, omega_fund, c, dz, fee_qomega_payload, ...
    core_idx, kerr_n2_core, fee_z_rk2_flag, kerr_custom_args)
%==========================================================================
% APPLY_KERR_STEP_SELECTED_LOCAL  (collapse the Kerr output-selection matrix)
%==========================================================================
% Select the NLSE or FEE Kerr helper and return only the outputs this step
% actually requested.
% When the driver marks Kerr disabled because |n2_kerr| is beneath the
% user-facing near-zero tolerance, this helper skips the Kerr substep
% entirely and only rebuilds |A_S|^2 if downstream diagnostics asked for it.
% When d_a_kerr is requested, both Kerr branches return the same applied
% finite-difference update (A_after - A_before)/dz so the diagnostic means
% the same thing regardless of which branch advanced the field.
% kerr_custom_args carries any extra user inputs for user-added Kerr logic
% at this helper boundary.

    intens_s = [];
    d_a_kerr = [];
    d_a_kerr_core = [];
    A_core_after_kerr = [];
    nt = size(A_S, 2);

    if ~kerr_enabled
        A_core_after_kerr = A_core_in;
        if need_intens_s
            intens_s = reshape(real(A_S .* conj(A_S)), nx, ny, nt);
        end
        return;
    end

    if use_nlse_flag
        if need_intens_s
            [A_S, A_core_after_kerr, intens_s] = apply_kerr_step_nlse( ...
                A_S, A_core_in, kerr_n2_xy, omega_fund, c, dz, core_idx, kerr_n2_core, nx, ny);
        else
            [A_S, A_core_after_kerr] = apply_kerr_step_nlse( ...
                A_S, A_core_in, kerr_n2_xy, omega_fund, c, dz, core_idx, kerr_n2_core, nx, ny);
        end
        if need_kerr_delta
            dz_real_like = cast(max(abs(double(real(dz))), eps), 'like', real(A_core_in(1)));
            d_a_kerr_core = (A_core_after_kerr - A_core_in) ./ dz_real_like;
        end
    else
        if need_intens_s && need_kerr_delta
            [A_S, A_core_after_kerr, d_a_kerr_core, intens_s] = apply_kerr_step_fee( ...
                A_S, A_core_in, kerr_n2_core, dz, fee_qomega_payload, core_idx, fee_z_rk2_flag, nx, ny);
        elseif need_intens_s
            [A_S, A_core_after_kerr, ~, intens_s] = apply_kerr_step_fee( ...
                A_S, A_core_in, kerr_n2_core, dz, fee_qomega_payload, core_idx, fee_z_rk2_flag, nx, ny);
        elseif need_kerr_delta
            [A_S, A_core_after_kerr, d_a_kerr_core] = apply_kerr_step_fee( ...
                A_S, A_core_in, kerr_n2_core, dz, fee_qomega_payload, core_idx, fee_z_rk2_flag, nx, ny);
        else
            [A_S, A_core_after_kerr] = apply_kerr_step_fee( ...
                A_S, A_core_in, kerr_n2_core, dz, fee_qomega_payload, core_idx, fee_z_rk2_flag, nx, ny);
        end
    end

    if need_kerr_delta
        [d_a_kerr, ~] = propagation_support.scatter_core_rows_to_full( ...
            d_a_kerr_core, core_idx, nx, ny, nt, d_a_kerr_core, []);
    end
end

function [A_S, A_core_out, intens_s, kerr_phase] = apply_kerr_step_nlse( ...
    A_S, A_core_in, n2_xy, omega_fund, c, dz, core_idx, n2_core_in, nx, ny)
%==========================================================================
% APPLY_KERR_STEP_NLSE  (NLSE version, exponential factor)
%==========================================================================
% Apply Kerr self-phase modulation using the NLSE prefactor in real space.
% This is the local-phase Kerr branch selected when use_nlse_flag=true in
% advance_z_step(...). Unlike apply_kerr_step_fee(...), it does not use the
% setup-built Q(omega) prefactor and instead applies the Kerr phase
% directly on the core-row field in real space.
% This uses an exponential split-step update with
% prefactor (omega_fund/c), and the scaled envelope A_S for which
% the solver-space intensity is I = |A_S|^2.
% GOVERNING CONTRIBUTION (scaled envelope A_S):
% dA_s/dz |_Kerr = +1i * (omega_fund/c) * n2(x,y) * |A_S|^2 * A_S,
% where n2(x,y) is the Kerr coefficient map.
%
% IMPLEMENTATION:
% 1) I(x,y,t) = |A_S|^2
% 2) Use the provided n2_xy(x,y) Kerr map.
% 3) phi(x,y,t) = (omega_fund/c) * n2(x,y) * I(x,y,t) * dz
% 4) A_S <- A_S .* exp(+1i * phi)
%
% INPUTS:
% A_S           : flattened current-step field view [Nx*Ny, Nt]
% A_core_in     : optional pre-gathered core-row field [Nc, Nt]
% n2_xy         : settled 2-D Kerr coefficient map on the current x/y grid
%                 passed into this step; the default Kerr update uses it
%                 directly without taking a spectral slice here
% omega_fund    : fundamental angular frequency [rad/s]
% c             : speed of light
% dz            : propagation step [m]
% core_idx      : active nonlinear rows in flattened (x,y)
% n2_core_in    : optional precomputed n2(core_idx) column/vector to avoid
%                 rebuilding the core-only slice from n2_xy
% nx, ny        : transverse grid sizes used when reshaping optional
%                 full-grid outputs
%
% OUTPUTS:
% A_S           : updated flattened field view [Nx*Ny, Nt]
% A_core_out    : updated core rows [numel(core_idx), Nt]
% intens_s      : optional reshaped |A_S|^2 diagnostic [Nx, Ny, Nt]
% kerr_phase    : optional reshaped phase factor exp(+1i * phi) [Nx, Ny, Nt]
%==========================================================================
% Core-only Kerr phase application on the flattened working field.

    nt = size(A_S, 2);
    nxy = nx * ny;
    intens_s = [];
    kerr_phase = [];
    if nargin >= 2 && ~isempty(A_core_in)
        A_core = A_core_in;
    else
        A_core = A_S(core_idx, :);
    end
    if (nargin >= 8) && ~isempty(n2_core_in)
        n2_core = reshape(n2_core_in, [], 1);
    else
        n2_col = reshape(n2_xy, nxy, 1);
        n2_core = n2_col(core_idx, :);
    end
    % Math block: build phi = (omega_fund/c) * n2 * |A|^2 * dz on the
    % active core rows, then apply exp(+1i * phi).

    intens0_core = real(A_core .* conj(A_core));
    n2_core = cast(n2_core, 'like', intens0_core);
    pref_w_over_c = cast(omega_fund / c, 'like', intens0_core);
    dz_like = cast(dz, 'like', intens0_core);
    phi_core = pref_w_over_c .* n2_core .* intens0_core .* dz_like;
    kerr_phase_core = exp(cast(1i, 'like', A_core) .* phi_core);

    A_core_out = A_core .* kerr_phase_core;
    A_S(core_idx, :) = A_core_out;
    if nargout >= 4
        % Build full-grid phase on demand; outside-core phase is unity.

        kerr_phase_2_d = ones(nxy, nt, 'like', A_S);
        kerr_phase_2_d(core_idx, :) = kerr_phase_core;
        kerr_phase = reshape(kerr_phase_2_d, nx, ny, nt);
    end

    if nargout >= 3
        intens_s = reshape(real(A_S .* conj(A_S)), nx, ny, nt);
    end
end

function [A_S, A_core_out, d_a_kerr_core, intens_s] = apply_kerr_step_fee( ...
    A_S, A_core_in, n2_core, dz, fee_qomega_payload, core_idx, use_rk2, nx, ny)
%==========================================================================
% APPLY_KERR_STEP_FEE  (shared FEE Kerr core for RK2/Euler updates)
%==========================================================================
% Shared FEE Kerr source-step owner for the frequency-resolved Kerr path.
% This is the FEE-form Kerr branch selected when use_nlse_flag=false in
% advance_z_step(...). The setup-owned fee_qomega_payload.qomega_w bundle
% stores
%   Q(omega) = (omega/c) * n_sell(omega_fund) / n_sell(omega)
% on the solver omega grid.
%
% INPUTS:
% A_S               : flattened current-step field view [Nx*Ny, Nt]
% A_core_in         : optional pre-gathered core-row field [Nc, Nt]
% n2_core           : core-row Kerr coefficient vector [numel(core_idx), 1]
%                     passed in directly from the settled step bundle
% dz                : propagation step [m]
% fee_qomega_payload: setup-owned omega-only FEE Kerr prefactor bundle
% core_idx          : active nonlinear rows in flattened (x,y)
% use_rk2           : true for RK2/trapezoid Kerr update, false for Euler
% nx, ny            : transverse grid sizes used when reshaping the
%                     optional full-grid intensity output
%
% OUTPUTS:
% A_S               : updated flattened field view [Nx*Ny, Nt]
% A_core_out        : updated core-row field [Nc, Nt]
% d_a_kerr_core     : applied Kerr update on the core rows [Nc, Nt]/m
% intens_s          : optional reshaped |A_S|^2 diagnostic [Nx, Ny, Nt]
%==========================================================================
% Shared FEE Kerr step core; wrappers select RK2 trapezoid or Euler stepping.
% The physical update is the same either way:
%   dA/dz = i * IFFT_t{ Q(omega) .* FFT_t{ n2(x,y) * |A|^2 * A } }
% on the core rows, then the updated core rows are scattered back into A_S.
% The helper can also return the applied core-row Kerr delta directly, so
% the optional full-grid Kerr diagnostic only needs one later scatter.

    nt = size(A_S, 2);
    if nargin >= 2 && ~isempty(A_core_in)
        A_core = A_core_in;
    else
        A_core = A_S(core_idx, :);
    end
    if isempty(n2_core)
        error('CerUPP:AdvanceStepMissingKerrN2Core', ...
            'apply_kerr_step_fee requires direct core-row Kerr coefficients.');
    end
    n2_core = reshape(n2_core, [], 1);

    % Math block: evaluate the FEE Kerr RHS on the core rows, then apply
    % either one Euler step or the RK2 trapezoid average in z.
    dz_like = cast(dz, 'like', A_core);
    d_a0_core = kerr_rhs_fee_core(A_core, n2_core, fee_qomega_payload);
    if use_rk2
        A_pred_core = A_core + dz_like .* d_a0_core;
        d_a1_core = kerr_rhs_fee_core(A_pred_core, n2_core, fee_qomega_payload);
        d_a_kerr_core = 0.5 .* (d_a0_core + d_a1_core);
    else
        d_a_kerr_core = d_a0_core;
    end

    A_core_out = A_core + dz_like .* d_a_kerr_core;
    A_S(core_idx, :) = A_core_out;
    if nargout >= 4
        intens_s = reshape(real(A_S .* conj(A_S)), nx, ny, nt);
    end
end

function d_a_core = kerr_rhs_fee_core(A_core, n2_core, fee_qomega_payload)
% KERR_RHS_FEE_CORE Compute the FEE Kerr RHS on core rows.
% A_CORE is [Ncore,Nt], N2_CORE supplies one Kerr coefficient per core row,
% and FEE_QOMEGA_PAYLOAD supplies the setup-owned omega-only Q(omega)
% operator prepared from qomega_3d in calculate_medium_properties_z.m.

    [nc, nt] = size(A_core);
    % Kerr polarization-like source on core rows:
    %   P_core = n2(x,y) * |A|^2 * A
    % This keeps spatially varying n2 inside the source before any k-space
    % operator is applied.

    n2_core = cast(reshape(n2_core, nc, 1), 'like', real(A_core(1)));
    p_core = (real(A_core .* conj(A_core)) .* A_core) .* n2_core;
    p_w_core = fft(p_core, [], 2);

    qw = fee_qomega_payload.qomega_w;
    if size(qw, 2) ~= nt
        error('CerUPP:AdvanceStepKerrFeeQomegaLengthMismatch', ...
            'fee_qomega_payload.qomega_w length (%d) must match Nt (%d).', size(qw, 2), nt);
    end
    k_core = ifft(p_w_core .* qw, [], 2);
    d_a_core = +cast(1i, 'like', A_core) .* k_core;
end


%==========================================================================
% V. File-local helper family: plasma wrapper and z-step coupling.
%==========================================================================
function [A_S, A_core_out, rhs_plasma, rho, rho_core_for_nla, ...
          rho_finite_scan, post_step_peak_rho, ...
          plasma_stiffness_diagnostic_step, plasma_softwarn_state, plasma_book, ...
          plasma_stage_workspace] = apply_plasma_step( ...
    A_S, A_core0, nx, ny, dz, z_curr, plasma_step_ctx, ...
    plasma_softwarn_state, plasma_custom_args, detect_blowup_cause_flag)
%==========================================================================
% APPLY_PLASMA_STEP Plasma z-update with Euler or RK2 outer-z integration.
%==========================================================================
% realspace_plasma_propagator.m returns the plasma RHS J for the current
% field. Euler uses J0 directly. RK2 uses J0 at A^n plus J1 at
% A_pred = A^n + dz*J0, then applies the trapezoid average
% rhs_plasma = 0.5*(J0 + J1).
%
% INPUTS:
% A_S                   : flattened full-grid field [Nx*Ny, Nt] used for
%                         writeback after the plasma substep
% A_core0               : start-of-step core-row field [Nc, Nt]
% nx, ny                : transverse grid size for optional full-grid scatter
% dz                    : propagation step [m]
% z_curr                : current z location [m] used in wrapped
%                         plasma-stage failure context
% plasma_step_ctx       : current-step plasma cfg, call template, geometry,
%                         RK order, and emitted-output gates
% plasma_softwarn_state : current plasma warning ledger
% plasma_custom_args    : owner-scoped extra named inputs for this plasma
%                         substep. The same settled plasma bucket is
%                         forwarded into realspace_plasma_propagator(...),
%                         where nested plasma.evolve_rho_td and
%                         plasma.keldysh structs stay available to the
%                         deeper plasma owners.
% detect_blowup_cause_flag
%                       : gates the private rho-end finite scan used for
%                         crash attribution on debug runs
%
% OUTPUTS:
% A_S                   : updated flattened full-grid field [Nx*Ny, Nt]
% A_core_out            : updated core-row field [Nc, Nt]
% rhs_plasma            : emitted plasma RHS on either core rows [Nc, Nt]
%                         or full-grid shape [Nx, Ny, Nt]
% rho                   : emitted post-step density on either core rows
%                         [Nc, Nt] or full-grid shape [Nx, Ny, Nt]
% rho_core_for_nla      : core-only density array reserved for downstream
%                         NLA physics and other post-step plasma consumers;
%                         when requested, this is the final post-step
%                         rho(t) surface regardless of the outer plasma RK order
% rho_finite_scan       : private density surface reserved for strict
%                         finite-scan crash attribution; when requested,
%                         this tracks the rho_end state actually evaluated
%                         on the current plasma step
% post_step_peak_rho    : step-owned scalar rho peak evaluated on the
%                         end-of-step field A^{n+1}; the driver uses this
%                         for run-level plasma peak trackers even when no
%                         full post-step rho surface is needed
% plasma_stiffness_diagnostic_step : optional plasma stiffness summary
% plasma_softwarn_state : updated plasma warning ledger
% plasma_book           : optional applied plasma accounting bundle
% plasma_stage_workspace : returned reusable plasma workspace for later
%                          stages or later steps when the stored shapes
%                          still match
    % Unpack the current-step plasma config once.

    plasma_flag = plasma_step_ctx.plasma_flag;
    plasma_runtime_cfg = plasma_step_ctx.runtime_cfg;
    plasma_call = plasma_step_ctx.call_template;
    core_idx = plasma_step_ctx.core_idx;
    dt_vec = plasma_step_ctx.dt_vec;
    plasma_z_rk2_flag = plasma_step_ctx.plasma_z_rk2_flag;
    plasma_evolve_t_rk2_flag = plasma_runtime_cfg.plasma_evolve_t_rk2_flag;
    emit_full_rho_grid = plasma_step_ctx.emit_full_rho_grid;
    emit_full_rhs_plasma_grid = plasma_step_ctx.emit_full_rhs_plasma_grid;
    need_plasma_book = plasma_step_ctx.need_plasma_book;
    need_plasma_end_rho_eval = plasma_step_ctx.need_plasma_end_rho_eval;
    need_private_rho_end_probe = logical( ...
        need_plasma_end_rho_eval || detect_blowup_cause_flag);
    plasma_stiffness_diagnostic_step = [];
    % major_step_custom_args was validated at the step boundary, so this
    % helper receives only the current plasma bucket here.

    nt = size(A_S, 2);
    plasma_book = [];
    rho_core_for_nla = [];
    rho_finite_scan = [];
    post_step_peak_rho = NaN;
    plasma_stage_workspace = struct();
    A_core_out = A_core0;
    A_core_end = A_core0;

    if plasma_flag
        dz_like = cast(dz, 'like', A_core0);
        plasma_call.plasma_runtime_cfg = plasma_runtime_cfg;
        plasma_call.plasma_softwarn_state = plasma_softwarn_state;
        plasma_call.A_core_in = A_core0;
        plasma_call.rho_only_eval = false;
        plasma_call.custom_args = plasma_custom_args;
        current_plasma_stage_tag = 'start';
        try
            % 1) Start-stage plasma solve on A^n.

            need_start_rho_surface = logical( ...
                ~plasma_z_rk2_flag && ~need_private_rho_end_probe);
            [diag0, j0_core, rho0_core, rho0_peak_rho, ...
             plasma_softwarn_state, plasma_book0, plasma_call] = ...
                propagation_support.run_plasma_stage_local( ...
                    plasma_call, A_core0, false, need_start_rho_surface, 'start', plasma_z_rk2_flag, A_core0);
            plasma_stiffness_diagnostic_step = propagation_support.merge_plasma_diag([], diag0);

            if ~plasma_z_rk2_flag
                rhs_plasma_core = j0_core;
                A_core_end = A_core0 + dz_like .* rhs_plasma_core;
                if need_private_rho_end_probe
                    % Euler does one extra rho-only probe on A^{n+1} when
                    % later diagnostics or finite scanning need the
                    % end-step rho surface. A_core_end above already holds
                    % the field at the end of this step.

                    current_plasma_stage_tag = 'rho_end';
                    [diag_end, ~, rho_end_core, post_step_peak_rho, plasma_softwarn_state, ~, plasma_call] = ...
                        propagation_support.run_plasma_stage_local( ...
                            plasma_call, A_core_end, true, true, 'rho_end', plasma_z_rk2_flag, A_core0);
                    plasma_stiffness_diagnostic_step = ...
                        propagation_support.merge_plasma_diag( ...
                            plasma_stiffness_diagnostic_step, diag_end);
                    rho_core = rho_end_core;
                    rho_finite_scan = real(rho_end_core);
                else
                    % If nothing downstream needs the full rho surface at
                    % A^{n+1}, reuse the start-stage rho sample outward but
                    % still do the scalar-only rho_end peak probe so the
                    % run-level peak history stays tied to the end-step
                    % field.

                    rho_core = rho0_core;
                    current_plasma_stage_tag = 'rho_end';
                    [diag_end_peak, ~, ~, post_step_peak_rho, plasma_softwarn_state, ~, plasma_call] = ...
                        propagation_support.run_plasma_stage_local( ...
                            plasma_call, A_core_end, true, false, 'rho_end', plasma_z_rk2_flag, A_core0);
                    plasma_stiffness_diagnostic_step = ...
                        propagation_support.merge_plasma_diag( ...
                            plasma_stiffness_diagnostic_step, diag_end_peak);
                end
                if need_plasma_book
                    plasma_book = plasma_book0;
                end
            else
                % 2) RK2 predictor solve on A_pred = A^n + dz * J0.

                current_plasma_stage_tag = 'predictor';
                A_pred_core = A_core0 + dz_like .* j0_core;
                need_predictor_rho_surface = ~need_private_rho_end_probe;
                [diag1, j1_core, rho1_core, rho1_peak_rho, plasma_softwarn_state, plasma_book1, plasma_call] = ...
                    propagation_support.run_plasma_stage_local( ...
                        plasma_call, A_pred_core, false, need_predictor_rho_surface, ...
                        'predictor', plasma_z_rk2_flag, A_core0);
                plasma_stiffness_diagnostic_step = ...
                    propagation_support.merge_plasma_diag( ...
                        plasma_stiffness_diagnostic_step, diag1);
                rhs_plasma_core = 0.5 .* (j0_core + j1_core);
                A_core_end = A_core0 + dz_like .* rhs_plasma_core;
                if need_private_rho_end_probe
                    % 3) Do one rho-only probe on A^{n+1} when later
                    % diagnostics or finite scanning still need the actual
                    % end-step rho surface. A_core_end above already holds
                    % the field at the end of this step.

                    current_plasma_stage_tag = 'rho_end';
                    [diag_end, ~, rho_end_core, post_step_peak_rho, plasma_softwarn_state, ~, plasma_call] = ...
                        propagation_support.run_plasma_stage_local( ...
                            plasma_call, A_core_end, true, true, 'rho_end', plasma_z_rk2_flag, A_core0);
                    plasma_stiffness_diagnostic_step = ...
                        propagation_support.merge_plasma_diag( ...
                            plasma_stiffness_diagnostic_step, diag_end);
                    rho_core = rho_end_core;
                    rho_finite_scan = real(rho_end_core);
                else
                    % If only the run-level rho peak is needed, keep the
                    % predictor-stage rho surface outward so rho does not
                    % collapse to [], but still probe the end-step field
                    % for the scalar rho peak so the recorded peak matches
                    % A^{n+1}.

                    rho_core = rho1_core;
                    current_plasma_stage_tag = 'rho_end';
                    [diag_end_peak, ~, ~, post_step_peak_rho, plasma_softwarn_state, ~, plasma_call] = ...
                        propagation_support.run_plasma_stage_local( ...
                            plasma_call, A_core_end, true, false, 'rho_end', plasma_z_rk2_flag, A_core0);
                    plasma_stiffness_diagnostic_step = ...
                        propagation_support.merge_plasma_diag( ...
                            plasma_stiffness_diagnostic_step, diag_end_peak);
                end
                if need_plasma_book
                    plasma_book = propagation_support.average_plasma_book_local(plasma_book0, plasma_book1);
                end
            end
        catch me_plasma_stage
            [plasma_error_id, plasma_error_msg] = propagation_support.plasma_stage_error_contract_local( ...
                current_plasma_stage_tag, plasma_z_rk2_flag, ...
                plasma_evolve_t_rk2_flag, me_plasma_stage, z_curr, dz);
            me_wrapped = MException(plasma_error_id, plasma_error_msg);
            me_wrapped = addCause(me_wrapped, me_plasma_stage);
            throw(me_wrapped);
        end
        A_core_out = A_core_end;
        A_S(core_idx, :) = A_core_out;
        dz_real_like = cast(double(real(dz)), 'like', real(A_core0(1)));
        rho_core_for_nla = real(rho_core);
        if need_plasma_book
            % This ledger is the plasma-substep |A|^2 field drop.

            plasma_field_drop_solver_core = ...
                real((real(A_core0 .* conj(A_core0)) - real(A_core_out .* conj(A_core_out))) ./ dz_real_like);
            plasma_book.field_energy_drop_solver_timeint_core = ...
                integrate_plasma_core_td_rows(plasma_field_drop_solver_core, dt_vec);
        end

        % Scatter rhs_plasma and rho independently so snapshot-only
        % consumers can request full-grid rho without forcing a matching
        % full-grid rhs_plasma expansion.
        if emit_full_rhs_plasma_grid
            rhs_plasma = propagation_support.scatter_core_rows_to_full( ...
                rhs_plasma_core, core_idx, nx, ny, nt, A_core0, []);
        else
            rhs_plasma = rhs_plasma_core;
        end
        if emit_full_rho_grid
            rho = propagation_support.scatter_core_rows_to_full( ...
                real(rho_core), core_idx, nx, ny, nt, real(A_core0(1)), []);
        else
            rho = real(rho_core);
        end
        if isempty(rho_finite_scan)
            rho_finite_scan = real(rho_core);
        end
        if isfield(plasma_call, 'stage_workspace') && isstruct(plasma_call.stage_workspace)
            plasma_stage_workspace = plasma_call.stage_workspace;
        end
        % soft-warning accumulation only; emit at run end in driver summary.

    else
        rhs_plasma = [];
        rho = [];
        rho_finite_scan = [];
        rho_core_for_nla = [];
        post_step_peak_rho = NaN;
        plasma_book = [];
        plasma_stiffness_diagnostic_step = [];
        plasma_stage_workspace = struct();
        A_core_out = A_core0;
    end
end

%==========================================================================
% VI. File-local helper family: NLA wrapper and loss accounting.
%==========================================================================
function [A_S, A_core_out, j_mpa_core, nla_diag_core, nla_softwarn_state, nla_book] = apply_nla_step( ...
    A_S, A_core_in, rho_core_for_nla, nx, ny, dz, nla_step_ctx, nla_softwarn_state, nla_custom_args)
% NLA/MPA update.
% - NLA is applied through the intensity loss law first and then mapped
%   back onto the complex envelope. In amplitude notation
%     dA/dz|_NLA = -S_NLA,time,   I = |A|^2.
%   CerUPP realizes that sink with the phase-preserving update
%     A <- A .* sqrt(I_new./I_old)
%   after first updating intensity over dz.
% - Static beta_K closure updates I with the chosen beta_K law, then applies
%   the same field rescaling A <- A .* sqrt(I_new./I_old).
% - Matched plasma-OFI closure keeps the same active plasma OFI rate law
%   W_ion(I) as the source step and only changes the density factor in
%     S_NLA,time = 0.5 * Udep_matched * density_scale * (W_ion(I)./I) .* A,
%   where Udep_matched is the setup-side optical depletion energy assigned
%   to each OFI event in the matched sink.
%   For the dynamic branch and the static sum_K sigma_K I^K branch,
%     dI/dz = -Udep_matched * rho_ofi_scale * W_ion(I)
%   or
%     dI/dz = -Udep_matched * max(rho_supply-rho,0) * W_ion(I),
%   depending on the selected OFI weighting mode.
%   In the single-order static case, choosing
%     Udep_matched = K*hbar*omega_fund
%   reproduces the usual single-K MPI loss.
%   Dynamic W_ion(I) is the same runtime Keldysh rate law that cerupp.m
%   built in Section 2E from the selected material inputs and then passed
%   into this step.
%   K_display only feeds the derived sigma_K,eff / beta_eff_* diagnostic
%   remap, while the static sum_K sigma_K I^K branch uses its local
%   log-slope K_eff(I)=d ln(W_ion)/d ln(I). sigma_K,eff and beta_eff_*
%   remain diagnostic summaries only.
% - If the selected static closure also uses remaining-neutral weighting,
%   its sink is multiplied by (rho_supply-rho)/rho_nt. By default
%   rho_supply=rho_nt; with a source-side reservoir override it follows
%   plasma_runtime_cfg.neutral_reservoir_m3.
%   Any out-of-range neutral fraction is warn-clipped back into [0,1] so
%   the applied sink stays nonnegative and bounded by the undepleted-
%   reservoir baseline. Tiny excursions may come from roundoff, while
%   larger ones point to an upstream inconsistency in rho or rho_supply.
%
% INPUTS:
% A_S                     : flattened full-grid field view [Nx*Ny, Nt]
%                           used for the final writeback after the NLA sink
% A_core_in               : core-row field array [Nc, Nt] for this same
%                           current step. Physically this is the field
%                           restricted to core_idx, and the NLA sink forms
%                           I0 = |A|^2 from these core rows.
% rho_core_for_nla        : [] for plasma-disabled or undepleted static-beta
%                           runs, otherwise the core-only [Nc, Nt] density
%                           array returned by the plasma step for this same
%                           z update
% nx, ny                  : full transverse grid size used when the helper
%                           reshapes the updated field back to [Nx, Ny, Nt]
% dz                      : NLA substep length [m]
% nla_step_ctx            : current-step NLA context carrying the selected
%                           runtime cfg, prebuilt closure mode selection,
%                           core geometry, neutral reservoir inputs, and
%                           accounting gates
% nla_softwarn_state      : current NLA warning ledger
% nla_custom_args         : owner-scoped extra named inputs for user-added
%                           NLA logic at this helper boundary
% OUTPUTS:
% A_S                     : updated flattened field view [Nx*Ny, Nt]
% A_core_out              : updated core-row field [Nc, Nt]
% j_mpa_core              : [] unless need_j_model_pre=true. When requested,
%                           this is the pre-step core-only NLA model-
%                           coefficient view returned by the selected
%                           closure. In the undepleted static branch this is
%                           intensity-only; depletion-aware branches may
%                           also depend on the current rho or remaining-
%                           neutral weighting.
% nla_diag_core           : core-only diagnostic bundle. The matched-
%                           Keldysh sigma_K,eff / beta_eff_full /
%                           beta_eff_applied surfaces and their raw
%                           intensity/rho reconstruction inputs are filled
%                           only when need_keldysh_effective_diag_maps=true;
%                           otherwise those fields remain empty while the
%                           physical NLA sink still applies normally
% nla_softwarn_state      : updated NLA warning ledger
% nla_book                : optional applied-loss accounting bundle from
%                           this same core-only NLA update
% The returned field A_S stays flattened as [Nx*Ny, Nt]. A_core_out,
% j_mpa_core, and the array fields inside nla_diag_core stay on core rows
% unless the caller later scatters them back out.
% nla_custom_args carries any extra user inputs for this helper.
    % I. Unpack the current-step NLA config, warning ledger, and outputs.

    nl_absorption_flag = nla_step_ctx.nl_absorption_flag;
    plasma_flag = nla_step_ctx.plasma_flag;
    nla_runtime_cfg = nla_step_ctx.runtime_cfg;
    nla_mode_payload = nla_step_ctx.mode_payload;
    nla_rk2_flag = nla_step_ctx.nla_rk2_flag;
    core_idx = nla_step_ctx.core_idx;
    plasma_runtime_cfg = nla_step_ctx.plasma_runtime_cfg;
    rho_nt_m3 = nla_step_ctx.rho_nt_m3;
    need_j_model_pre = nla_step_ctx.need_j_model_pre;
    need_nla_book = nla_step_ctx.need_nla_book;
    need_keldysh_effective_diag_maps = nla_step_ctx.need_keldysh_effective_diag_maps;
    num_core = numel(core_idx);
    nla_diag_core = struct( ...
        'sigma_k_eff', [], ...
        'beta_eff_full', [], ...
        'beta_eff_applied', [], ...
        'i_eval', [], ...
        'rho_core', []);
    nla_book = [];
    A_core_out = A_core_in;

    % II. Exit early when no NLA sink is active on this step.
    if ~nl_absorption_flag
        j_mpa_core = [];
        return;
    end
    resolved_nla_closure = struct_utils.req_struct_field( ...
        nla_mode_payload, 'resolved_closure', 'nla_step_ctx.mode_payload');
    keldysh_nla_enabled = logical(struct_utils.req_struct_field( ...
        resolved_nla_closure, 'keldysh_nla_enabled', 'nla_mode_payload.resolved_closure'));
    static_nla_mode_id = uint8(nla_mode_payload.static_nla_mode_id);

    % III. Math block: gather the pre-NLA core rows and form I0 = |A|^2 there.
    nt = size(A_S, 2);
    if (static_nla_mode_id == uint8(0)) && ~keldysh_nla_enabled
        j_mpa_core = [];
        if need_j_model_pre || need_nla_book
            if isa(A_S, 'single')
                zero_core = zeros(num_core, nt, 'single');
                tiny_i = realmin('single');
            elseif isa(A_S, 'double')
                zero_core = zeros(num_core, nt, 'double');
                tiny_i = realmin('double');
            else
                error('CerUPP:AdvanceStepNlaUnsupportedIntensityClass', ...
                    'I0_core must be single or double; got class %s.', class(A_S));
            end
            if need_j_model_pre
                j_mpa_core = zero_core;
            end
            if need_nla_book
                nla_book = nla_support.build_bookkeeping( ...
                    zero_core, [], true(size(zero_core)), ...
                    propagation_support.want_full_bookkeeping_ledger_local(nla_runtime_cfg), ...
                    zero_core, zero_core, zero_core, ...
                    dz, tiny_i, []);
            end
        end
        return;
    end

    % Math block: gather the pre-NLA core rows, then build I0 = |A|^2 there.
    A_core = A_core_in;
    i0_core = real(A_core .* conj(A_core));
    need_neutral_fraction = logical(struct_utils.req_struct_field( ...
        resolved_nla_closure, 'uses_neutral_fraction', 'nla_mode_payload.resolved_closure'));

    % IV. Build the rho view and any remaining-neutral weight seen by the NLA law.
    skip_static_support_arrays = ~need_neutral_fraction && ~need_nla_book;
    if isempty(rho_core_for_nla)
        if plasma_flag && need_neutral_fraction
            error('CerUPP:AdvanceStepNlaMissingRhoInput', ...
                ['rho_core_for_nla must be nonempty when plasma_flag=true and the active NLA closure uses neutral fraction. ', ...
                 'Plasma-disabled runs or static undepleted beta_K runs should pass rho=[].']);
        end
        if skip_static_support_arrays
            rho_core = [];
        else
            rho_core = zeros(num_core, nt, 'like', i0_core);
        end
    else
        if ~ismatrix(rho_core_for_nla) || (size(rho_core_for_nla, 1) ~= num_core) || (size(rho_core_for_nla, 2) ~= nt)
            error('CerUPP:AdvanceStepNlaInvalidRhoShape', ...
                ['rho_core_for_nla must be either [] or core-only [numel(core_idx),nt]. ', ...
                 'Got size %s.'], mat2str(size(rho_core_for_nla)));
        end
        rho_core = real(rho_core_for_nla);
    end

    % IV. Build the density factor used by the active NLA law.
    % OFI-based sinks may read the same reservoir state tracked by the
    % plasma source, but the selected NLA-side weighting branch still
    % decides the applied sink strength. Remaining-neutral matched-OFI
    % closure uses max(rho_supply-rho,0), fixed-density matched-OFI
    % closure stays on rho_ofi_scale, and the static remaining-neutral
    % beta_K sink uses the clipped neutral fraction
    % (rho_supply-rho)/rho_nt in [0,1].
    rho_nt = [];
    remaining_neutral_core = [];
    if skip_static_support_arrays
        neutral_frac_clamp_mask = false(0, 0);
    else
        neutral_frac_clamp_mask = false(size(i0_core));
    end
    if need_neutral_fraction
        rho_nt_val = double(real(rho_nt_m3));
        if ~(isscalar(rho_nt_val) && isfinite(rho_nt_val) && (rho_nt_val > 0))
            error('CerUPP:AdvanceStepNlaInvalidRhoNt', ...
                'rho_nt_m3 must be finite and > 0 for depletion-aware or OFI-based NLA.');
        end
        rho_nt = cast(rho_nt_val, 'like', i0_core);
        rho_neutral_supply_val = double(real(struct_utils.req_struct_field( ...
            plasma_runtime_cfg, 'neutral_reservoir_m3', ...
            'advance_z_step plasma_runtime_cfg')));
        if ~(isscalar(rho_neutral_supply_val) && isfinite(rho_neutral_supply_val) && ...
                (rho_neutral_supply_val > 0))
            error('CerUPP:AdvanceStepNlaInvalidRuntimeCfgNeutralReservoir', ...
                'plasma_runtime_cfg.neutral_reservoir_m3 must be one finite real scalar > 0.');
        end
        rho_neutral_supply = cast(rho_neutral_supply_val, 'like', i0_core);
        % When the selected optical closure uses remaining-neutral
        % weighting, the OFI-based sink reuses the same nonnegative
        % reservoir fraction as the plasma OFI source. If the selected
        % optical closure instead stays on rho_ofi_scale, this reservoir
        % state is still tracked here for diagnostics but does not set the
        % applied sink strength.

        remaining_neutral_raw = rho_neutral_supply - rho_core;
        remaining_neutral_core = max(remaining_neutral_raw, cast(0, 'like', remaining_neutral_raw));
        if any(~isfinite(remaining_neutral_core(:)))
            error('CerUPP:AdvanceStepNlaNonFiniteRemainingNeutral', ...
                'Computed remaining-neutral reservoir contains non-finite values.');
        end
        if keldysh_nla_enabled
            nla_loss_weight_core = remaining_neutral_core ./ rho_nt;
        else
            neutral_frac_raw = remaining_neutral_raw ./ rho_nt;
            if any(~isfinite(neutral_frac_raw(:)))
                error('CerUPP:AdvanceStepNlaNonFiniteNeutralFraction', ...
                    'Computed neutral fraction contains non-finite values.');
            end
            neutral_min = min(neutral_frac_raw(:));
            neutral_max = max(neutral_frac_raw(:));
            neutral_low_mask = (neutral_frac_raw < 0);
            neutral_high_mask = (neutral_frac_raw > 1);
            neutral_frac_clamp_mask = neutral_low_mask | neutral_high_mask;
            if any(neutral_frac_clamp_mask(:))
                low_count = nnz(neutral_low_mask);
                high_count = nnz(neutral_high_mask);
                nla_softwarn_state = propagation_support.record_nla_neutral_fraction_clamp_local( ...
                    nla_softwarn_state, low_count, high_count, neutral_min, neutral_max);
                [nla_softwarn_state, ~] = warning_utils.cerupp_warn_once( ...
                    nla_softwarn_state, 'NLA_NEUTRAL_FRACTION_CLAMPED', ...
                    'CerUPP:NLA:NeutralFractionClamped', ...
                    ['Static remaining-neutral beta_K weight left [0,1] (below0=%d, above1=%d, raw_min=%.3e, raw_max=%.3e). ' ...
                     'Clamping the normalized beta_K weight back to [0,1] so the static sink stays nonnegative and bounded by the undepleted baseline.'], ...
                    low_count, high_count, neutral_min, neutral_max);
                neutral_frac_raw = max(neutral_frac_raw, 0);
                neutral_frac_raw = min(neutral_frac_raw, 1);
            end
            nla_loss_weight_core = neutral_frac_raw;
        end
    else
        if skip_static_support_arrays
            nla_loss_weight_core = cast(1, 'like', i0_core);
        else
            nla_loss_weight_core = ones(size(i0_core), 'like', i0_core);
        end
    end
    % V. Apply the selected NLA sink on the core-row intensity.
    % - matched closure: dynamic W_ion(I)-based optical depletion using
    %   the selected Keldysh source family together with the NLA-side
    %   weighting choice prepared above,
    % - static mode 1 : one surrogate beta_K sink,
    % - static mode 2 : summed multi-order surrogate sink.
    % static_nla_mode_id stays numeric here because nla_mode_payload was
    % already validated once at setup.

    j_core = [];
    i_new = i0_core;
    dz_like = cast(dz, 'like', i0_core);
    if isa(i0_core, 'single')
        tiny_i = realmin('single');
    elseif isa(i0_core, 'double')
        tiny_i = realmin('double');
    else
        error('CerUPP:AdvanceStepNlaUnsupportedIntensityClass', ...
            'I0_core must be single or double; got class %s.', class(i0_core));
    end
    if keldysh_nla_enabled
        [i_new, j_core, nla_diag_core, nla_softwarn_state] = nla_support.apply_matched_kernel( ...
            i0_core, remaining_neutral_core, nla_runtime_cfg, need_j_model_pre, ...
            nla_rk2_flag, tiny_i, dz_like, need_keldysh_effective_diag_maps, ...
            nla_softwarn_state, nla_diag_core);
        if need_keldysh_effective_diag_maps
            nla_diag_core.rho_core = rho_core;
        end
    elseif static_nla_mode_id == uint8(1)
        [i_new, j_core, nla_softwarn_state] = nla_support.apply_static_single_kernel( ...
            i0_core, nla_loss_weight_core, nla_mode_payload, ...
            need_j_model_pre, dz_like, nla_softwarn_state);
    elseif static_nla_mode_id == uint8(2)
        [i_new, j_core] = nla_support.apply_static_multi_kernel( ...
            i0_core, nla_loss_weight_core, nla_mode_payload, ...
            need_j_model_pre, nla_rk2_flag, dz_like);
    else
        error('CerUPP:AdvanceStepNlaInvalidNlaModePayload', ...
            'nla_mode_payload.static_nla_mode_id must be 0(none), 1(single), or 2(multi); got %d.', ...
            double(static_nla_mode_id));
    end

    % VI. Write the updated intensity back onto A_S and emit accounting data.
    [a_s_full, A_core_out, j_mpa_core, nla_book, nla_softwarn_state] = nla_support.finalize_applied_update( ...
        reshape(A_S, nx, ny, nt), [], A_core, core_idx, i0_core, i_new, rho_core, dz, tiny_i, ...
        j_core, need_nla_book, neutral_frac_clamp_mask, nla_softwarn_state, ...
        propagation_support.want_full_bookkeeping_ledger_local(nla_runtime_cfg));
    A_S = reshape(a_s_full, nx * ny, nt);
end

%======================================================================%
% VII. Late-file runtime/validation/timing helpers.
%======================================================================%
function timeint_core = integrate_plasma_core_td_rows(core_td_rows, dt_vec)
% Integrate one core-row plasma history over time with the same trapezoid
% weights implied by the authoritative dt_vec.

    if isempty(core_td_rows)
        timeint_core = [];
        return;
    end
    nt = size(core_td_rows, 2);
    if nt <= 1
        timeint_core = zeros(size(core_td_rows, 1), 1, 'like', real(core_td_rows(:, 1)));
        return;
    end
    dt_row = reshape(cast(double(dt_vec(:)), 'like', real(core_td_rows(1))), 1, []);
    if numel(dt_row) ~= (nt - 1)
        error('CerUPP:AdvanceStepInvalidPlasmaDtForIntegration', ...
            'Expected numel(dt_vec) == Nt-1 (%d), got %d.', nt - 1, numel(dt_row));
    end
    % Build the nonuniform trapezoid weights once, then apply them to every
    % core row at once.
    trapz_weights = zeros(1, nt, 'like', dt_row);
    trapz_weights(1) = 0.5 .* dt_row(1);
    trapz_weights(end) = 0.5 .* dt_row(end);
    if nt > 2
        trapz_weights(2:end-1) = 0.5 .* (dt_row(1:end-1) + dt_row(2:end));
    end
    timeint_core = real(core_td_rows) * trapz_weights.';
end

function assert_step_operator_shape_local(arr, expected_size, arr_name)
% Cheap contract guard against implicit-expansion operator misuse.

    if ~isequal(size(arr), expected_size)
        error('CerUPP:AdvanceStepInvalidOperatorShape', ...
            '%s must be size %s; got %s.', ...
            arr_name, mat2str(expected_size), mat2str(size(arr)));
    end
end

function A_F = project_supported_spectral_bins_local(A_F, mask_f_in, mask_f_w_in)
% Binary runtime gate for k and omega bins: nonzero is admitted, zero is
% rejected.

    if ~isempty(mask_f_in)
        A_F = A_F .* cast(mask_f_in ~= 0, 'like', A_F);
    end
    if ~isempty(mask_f_w_in)
        A_F = A_F .* cast(mask_f_w_in ~= 0, 'like', A_F);
    end
end

function [a_rows, A_F_projected] = project_time_rows_onto_supported_spectral_bins_local( ...
        a_rows, nx, ny, mask_f_in, mask_f_w_in)
% Rebuild A_F and reapply the same binary admit/reject gate before the
% next same-step stage reads the field.

    nt = size(a_rows, 2);
    a_ssf_project = reshape(fft(a_rows, [], 2), nx, ny, nt);
    A_F_projected = project_supported_spectral_bins_local( ...
        fft2(a_ssf_project), mask_f_in, mask_f_w_in);
    a_ssf_project = ifft2(A_F_projected);
    a_rows = reshape(ifft(a_ssf_project, [], 3), nx * ny, nt);
end

function [A_S, A_F, A_SSF] = finish_step_closeout_local( ...
        a_ssf_linear, lin_half_factor, mask_f_in, mask, ...
        mask_f_w_in, ...
        need_return_a_s, need_return_a_ssf)
% Finish one split-step by applying the return linear half-step, binary
% support cleanup, the real-space absorber, and whatever field views this
% caller asked to keep.

    need_closeout_ssf = need_return_a_s || need_return_a_ssf;
    A_F = fft2(a_ssf_linear);
    A_F = A_F .* lin_half_factor;
    A_F = project_supported_spectral_bins_local( ...
        A_F, mask_f_in, mask_f_w_in);
    a_ssf_closeout = ifft2(A_F);
    a_ssf_closeout = a_ssf_closeout .* cast(mask, 'like', a_ssf_closeout);
    A_F = fft2(a_ssf_closeout);
    A_F = project_supported_spectral_bins_local(A_F, mask_f_in, mask_f_w_in);
    if need_closeout_ssf
        a_ssf_closeout = ifft2(A_F);
    end
    if need_return_a_ssf
        A_SSF = a_ssf_closeout;
    else
        A_SSF = [];
    end
    if need_return_a_s
        A_S = ifft(a_ssf_closeout, [], 3);
    else
        A_S = [];
    end
end

function stage_timer = start_stage_timer_local(timing_flag)
% Return one timer token when step timing is enabled.

    if timing_flag
        stage_timer = tic;
    else
        stage_timer = [];
    end
end

function step_runtime_meta = finish_stage_timer_local(step_runtime_meta, timing_field, stage_timer)
% Add one completed stage duration into the named timing bucket.

    if isempty(stage_timer)
        return;
    end
    step_runtime_meta.timing.(timing_field) = ...
        step_runtime_meta.timing.(timing_field) + toc(stage_timer);
end
