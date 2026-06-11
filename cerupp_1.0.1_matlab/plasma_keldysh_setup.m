classdef plasma_keldysh_setup
%PLASMA_KELDYSH_SETUP Dynamic-Keldysh setup math and lookup builder.
% This class holds the solid-state Keldysh formulas used to build the
% runtime per-neutral W_ion(I) law plus the sigma/beta curves used for
% setup diagnostics.
% Formula-path map:
% - keldysh_solid_interband_rate(...) evaluates the solid-state interband
%   rate on one sampled gamma surface and chooses between the built-in
%   branches below.
% - keldysh_original_qseries_rate_local(...) is the legacy transparent-
%   solid Q-series branch of L. V. Keldysh, Sov. Phys. JETP 20,
%   1307-1314 (1965).
% - keldysh_interference_corrected_ckld_rate_local(...) is the
%   interference-corrected transparent-solid cKLD branch of
%   N. S. Shcheblanov et al., Phys. Rev. A 96, 063410 (2017), written in
%   Kane-band two-band notation of E. O. Kane, J. Phys. Chem. Solids 1,
%   249-261 (1957).
% cerupp.m keeps the setup knobs, while plasma_keldysh_setup_support.m
% owns the longer setup-side validation, labels, and runtime packaging
% around this math.
% Edit this file for Keldysh formulas, quadrature, or runtime W_ion(I)
% lookup math.

    methods (Static)

        function [kcfg, run_warn_state] = build_runtime_cfg_from_setup(setup_cfg, run_warn_state)
        % Build the runtime Keldysh cfg from one settled setup record.
        % This is the public bridge from setup inputs into the live
        % runtime W_ion(I) law and its attached diagnostic surfaces.

            [kcfg, run_warn_state] = plasma_keldysh_setup_support( ...
                'build_runtime_cfg_from_setup', setup_cfg, run_warn_state);
        end
        function runtime_signature = build_runtime_signature_from_setup(setup_cfg)
        % Build the compact signature used to label one resolved Keldysh
        % runtime choice in cache files and setup reports.

            runtime_signature = plasma_keldysh_setup_support( ...
                'build_runtime_signature_from_setup', setup_cfg);
        end
        function policy = resolve_policy(cfg)
        % Return the fixed live-path policy record shared by the setup
        % bridge and the math-facing Keldysh builders.

            if nargin < 1 || ~isstruct(cfg)
                error('CerUPP:InvalidKeldyshPolicyCfg', ...
                    'resolve_policy requires an explicit struct cfg.');
            end
            policy = struct( ...
                'keldysh_reference_k_mode', 'discrete_threshold', ...
                'keff_bookkeeping_mode', 'display_k', ...
                'invalid_w_interp_bins_policy', 'warn_low_zero_high_clamp', ...
                'w_interp_contract_policy', 'error');
        end
        function [keldysh_ctrl, run_warn_state, setup_physics_rewrite_report] = ...
                resolve_driver_controls( ...
                medium_spec, sigma_k_vec, me, run_warn_state, ...
                setup_physics_rewrite_report, ...
                record_setup_physics_rewrite_fn, init_setup_physics_rewrite_report_fn, ...
                keldysh_enabled_requested, keldysh_display_k_requested, ...
                keldysh_lookup_csv_name_requested, ...
                air_dynamic_keldysh_contract_needed, ...
                air_static_placeholder_contract_needed)
        % Resolve the driver-facing Keldysh control record from the setup
        % knobs before the runtime builder runs.

            [keldysh_ctrl, run_warn_state, setup_physics_rewrite_report] = ...
                plasma_keldysh_setup_support( ...
                'resolve_driver_controls', ...
                medium_spec, sigma_k_vec, me, run_warn_state, ...
                setup_physics_rewrite_report, ...
                record_setup_physics_rewrite_fn, init_setup_physics_rewrite_report_fn, ...
                keldysh_enabled_requested, keldysh_display_k_requested, ...
                keldysh_lookup_csv_name_requested, ...
                air_dynamic_keldysh_contract_needed, ...
                air_static_placeholder_contract_needed);
        end
        function medium_kind = medium_kind_from_spec(medium_spec)
        % Classify medium_spec.name into the built-in medium family labels
        % used by Keldysh setup validation and branch selection.

            medium_kind = plasma_keldysh_setup_support( ...
                'medium_kind_from_spec', medium_spec);
        end
        function requested_name = requested_ofi_model_name_from_spec(medium_spec)
        % Return the built-in OFI-family label implied by the canonical
        % medium selection.

            requested_name = plasma_keldysh_setup_support( ...
                'requested_ofi_model_name_from_spec', medium_spec);
        end
        function medium_spec = attach_ofi_model_policy_labels( ...
                medium_spec, keldysh_enabled, k_power_vec_2, sigma_k_vec, plasma_flag, ion_routine_flag)
        % Tag medium_spec with the requested built-in OFI family and the
        % currently active closure family.

            medium_spec = plasma_keldysh_setup_support( ...
                'attach_ofi_model_policy_labels', ...
                medium_spec, keldysh_enabled, k_power_vec_2, sigma_k_vec, plasma_flag, ion_routine_flag);
        end
        function ofi_branch_active = is_ofi_branch_active(plasma_flag, ion_routine_flag)
        % Resolve whether the OFI source branch is physically active this
        % run from the driver-owned plasma switch and ion routine choice.

            ofi_branch_active = plasma_keldysh_setup_support( ...
                'is_ofi_branch_active', plasma_flag, ion_routine_flag);
        end
    end

    methods (Static, Hidden)
% Hidden math kernels and small numeric helpers:

        function y = dawson_real(x)
        % Real-valued Dawson approximation in piecewise rational form.
        % Region split:
        % - |x| < 3.25   : direct rational fit in x^2
        % - 3.25 <= |x| < 6.25 : reciprocal-x rational fit
        % - 6.25 <= |x| <= 1.0e9 : second reciprocal-x rational fit
        % - |x| > 1.0e9         : asymptotic 1/(2x)
        % The Keldysh Q-series calls this repeatedly, so setup keeps the helper
        % local and lightweight.

            x = double(real(x));
            if ~all(isfinite(x(:)))
                bad_idx = find(~isfinite(x), 1, 'first');
                error('plasma_keldysh_setup:InvalidDawsonInput', ...
                    'Non-finite Dawson input encountered at index %d.', bad_idx);
            end

            [an, ad, bn, bd, cn, cd] = plasma_keldysh_setup.plasma_keldysh_dawson_coeffs_local();
            ax = abs(x);
            y = zeros(size(x), 'like', x);
            sx = ones(size(x), 'like', x);
            sx(x < 0) = -1;

            m1 = (ax < 3.25);
            if any(m1(:))
                t1 = ax(m1) .* ax(m1);
                y(m1) = x(m1) .* polyval(an, t1) ./ polyval(ad, t1);
            end

            m2 = (~m1) & (ax < 6.25);
            if any(m2(:))
                t2 = 1.0 ./ (ax(m2) .* ax(m2));
                y_abs2 = (1.0 ./ ax(m2)) + t2 .* polyval(bn, t2) ./ ...
                         (plasma_keldysh_setup.plasma_keldysh_p1evl_vec_local(t2, bd) .* ax(m2));
                y(m2) = 0.5 .* sx(m2) .* y_abs2;
            end

            m3 = (~m1) & (~m2) & (ax > 1.0e9);
            if any(m3(:))
                y(m3) = 0.5 ./ x(m3);
            end

            m4 = (~m1) & (~m2) & (~m3);
            if any(m4(:))
                t4 = 1.0 ./ (ax(m4) .* ax(m4));
                y_abs4 = (1.0 ./ ax(m4)) + t4 .* polyval(cn, t4) ./ ...
                         (plasma_keldysh_setup.plasma_keldysh_p1evl_vec_local(t4, cd) .* ax(m4));
                y(m4) = 0.5 .* sx(m4) .* y_abs4;
            end

            bad_y = ~isfinite(y);
            if any(bad_y(:))
                bad_idx = find(bad_y, 1, 'first');
                error('plasma_keldysh_setup:NonFiniteDawson', ...
                    ['Non-finite Dawson approximation output at index %d. ' ...
                     'Refusing silent Inf/NaN->0 clamp in physics path.'], ...
                    bad_idx);
            end
        end

        function [k_bookkeeping_ref, bookkeeping_reference_info, soft_warn_state] = ...
                compute_keldysh_bookkeeping_reference_k( ...
                i_eval, omega, eg_j, mred_kg, n_fund, ep0, c, qe, hbar, ...
                use_solid_state_keldysh_flag, bookkeeping_reference_mode, soft_warn_state)
        %COMPUTE_KELDYSH_BOOKKEEPING_REFERENCE_K Choose one scalar diagnostic exponent.
        % The default live rule evaluates the effective gap at the chosen
        % reference intensity I_ref = i_eval and then applies the same
        % near-integer threshold rule used by
        % keldysh_solid_interband_rate(...).
        % It first converts the reference intensity into the in-medium
        % field amplitude
        %   E_ref = sqrt(2 I_ref / (n_fund*ep0*c)),
        % then forms
        %   gamma_ref = omega*sqrt(mred_kg*Eg_J) / (abs(qe)*E_ref).
        % That gamma_ref is passed through the same elliptic-integral
        % effective-gap evaluation used by the solid-state rate helper, so
        % the default K_display uses the same threshold-order rule at that
        % reference point:
        %   nu_cont = E_gap_eff(I_ref)/(hbar*omega) + 1
        %   nu_int  = floor(nu_cont + nu_tol)
        % The selected scalar K_display is this nu_int value; the simpler
        % ceil(E_gap_eff/(hbar*omega)) expression is only a rough mnemonic.
        % Returns the selected scalar K_display value, the second-output
        % metadata record that stores the gap ratio and threshold-order
        % details behind that choice, and the validated or normalized
        % setup-side soft_warn_state surface.

            eg_j = double(eg_j);
            i_eval = double(i_eval);
            omega = double(omega);
            mred_kg = double(mred_kg);
            n_fund = double(n_fund);
            ep0 = double(ep0);
            c = double(c);
            qe = double(qe);
            hbar = double(hbar);

            if nargin < 10 || isempty(use_solid_state_keldysh_flag)
                use_solid_state_keldysh_flag = true;
            end
            if nargin < 11 || isempty(bookkeeping_reference_mode)
                bookkeeping_reference_mode = 'discrete_threshold';
            elseif isstring(bookkeeping_reference_mode) && isscalar(bookkeeping_reference_mode)
                bookkeeping_reference_mode = char(bookkeeping_reference_mode);
            end
            if nargin < 12 || isempty(soft_warn_state)
                soft_warn_state = struct();
            elseif ~isstruct(soft_warn_state)
                error('CerUPP:Keldysh:InvalidSoftWarnState', ...
                    'soft_warn_state must be a struct or empty ([]).');
            end
            soft_warn_state = struct_utils.ensure_warned_keys_map(soft_warn_state);
            if ~ischar(bookkeeping_reference_mode)
                error('CerUPP:Keldysh:InvalidDisplayKReferenceModeType', ...
                    'The default K_display reference mode must be a char/string scalar.');
            end
            bookkeeping_reference_mode = lower(strtrim(bookkeeping_reference_mode));
            if ~strcmp(bookkeeping_reference_mode, 'discrete_threshold')
                error('CerUPP:Keldysh:InvalidDisplayKReferenceMode', ...
                    ['The default K_display reference mode must be ''discrete_threshold''; ', ...
                     'got ''%s''.'], ...
                    bookkeeping_reference_mode);
            end
            plasma_setup_support.require_supported_solid_keldysh_convention_local( ...
                use_solid_state_keldysh_flag, 'compute_keldysh_bookkeeping_reference_k');

            if ~isscalar(i_eval) || ~isscalar(eg_j) || ~isscalar(omega) || ...
                    ~isscalar(mred_kg) || ~isscalar(n_fund) || ~isscalar(ep0) || ...
                    ~isscalar(c) || ~isscalar(qe) || ~isscalar(hbar) || ...
                    ~isfinite(i_eval) || ~isfinite(eg_j) || ~isfinite(omega) || ...
                    ~isfinite(mred_kg) || ~isfinite(n_fund) || ~isfinite(ep0) || ...
                    ~isfinite(c) || ~isfinite(qe) || ~isfinite(hbar) || ...
                    (i_eval <= 0) || (eg_j <= 0) || (omega <= 0) || ...
                    (mred_kg <= 0) || (n_fund <= 0) || (ep0 <= 0) || ...
                    (c <= 0) || (abs(qe) <= 0) || (hbar <= 0)
                error('CerUPP:Keldysh:InvalidDisplayKReferenceInputs', ...
                    ['compute_keldysh_bookkeeping_reference_k requires finite positive scalar ', ...
                     'K_display reference inputs I_ref/Eg_J/omega/mred_kg/n_fund/ep0/c/qe/hbar; ', ...
                     'got I_ref=%g, Eg_J=%g, omega=%g, mred_kg=%g, n_fund=%g, ep0=%g, c=%g, ', ...
                     'qe=%g, hbar=%g.'], ...
                    double(i_eval), double(eg_j), double(omega), double(mred_kg), ...
                    double(n_fund), double(ep0), double(c), double(qe), double(hbar));
            end

            efield_ref = sqrt(max((2.0 * i_eval) / (n_fund * ep0 * c), 0.0));
            if ~(isfinite(efield_ref) && (efield_ref > 0))
                error('CerUPP:Keldysh:InvalidDisplayKReferenceField', ...
                    ['Reference intensity I_ref=%g W/m^2 produced an invalid in-medium field amplitude ', ...
                     'E_ref=%g V/m. Fix I_ref, n_fund, ep0, or c before requesting the automatic ', ...
                     'K_display selection.'], ...
                    double(i_eval), double(efield_ref));
            end
            gamma_ref = omega * sqrt(mred_kg * eg_j) / (abs(qe) * efield_ref);
            if ~(isfinite(gamma_ref) && (gamma_ref > 0))
                error('CerUPP:Keldysh:InvalidDisplayKReferenceGamma', ...
                    ['Reference intensity I_ref=%g W/m^2 produced an invalid Keldysh gamma_ref=%g. ', ...
                     'Fix the K_display reference inputs first.'], ...
                    double(i_eval), double(gamma_ref));
            end
            [~, x_ref, nu_cont_ref, nu_int_ref] = ...
                plasma_keldysh_setup.solid_state_threshold_terms_local( ...
                gamma_ref, omega, eg_j, hbar);
            eg_tilde_ref = x_ref * double(hbar) * double(omega);
            k_bookkeeping_ref = double(nu_int_ref);
            bookkeeping_reference_info = struct( ...
                'mode', bookkeeping_reference_mode, ...
                'gap_ratio', double(x_ref), ...
                'threshold_order', double(nu_int_ref), ...
                'nu_cont', double(nu_cont_ref), ...
                'nu_int', double(nu_int_ref), ...
                'reference_intensity_wm2', double(i_eval), ...
                'gamma_ref', double(gamma_ref), ...
                'eg_tilde_ref_j', double(eg_tilde_ref), ...
                'k_bookkeeping_reference', double(k_bookkeeping_ref));
        end

        function [gamma, x, nu_cont, nu_int, ratio, gamma1, k2, e2] = ...
                solid_state_threshold_terms_local(gamma, omega, eg_j, hbar)
        % Shared solid-state threshold terms for the reference-K path and
        % the branch-specific interband-rate kernels.

            gamma = max(double(gamma(:)), 1e-12);
            omega = double(omega);
            eg_j = double(eg_j);
            hbar = double(hbar);

            % Standard solid-state Keldysh elliptic-integral parameters.
            % MATLAB ellipke(m) takes the elliptic parameter m directly, so
            % gamma1 and gamma2 are passed as parameter values rather than
            % square-root moduli. CerUPP floors gamma at a tiny positive
            % value and clips gamma1/gamma2 away from the exact ellipke(...)
            % endpoint only as a numerical regularization for stable
            % evaluation, not as a separate physics convention.
            gamma1 = gamma.^2 ./ (1 + gamma.^2);
            gamma2 = 1 ./ (1 + gamma.^2);
            gamma1 = min(max(gamma1, 0.0), 1.0 - eps);
            gamma2 = min(max(gamma2, 0.0), 1.0 - eps);

            [k1, e1] = ellipke(gamma1);
            [k2, e2] = ellipke(gamma2);
            if any(~isfinite(k1(:)) | ~isfinite(e1(:)) | ~isfinite(k2(:)) | ~isfinite(e2(:)))
                error('CerUPP:Keldysh:NonFiniteElliptic', ...
                    'Non-finite elliptic-integral values in Keldysh rate evaluation.');
            end

            % Eg_tilde is the effective band gap. x = Eg_tilde/(hbar*omega)
            % then sets nu_cont together with the tolerance-stabilized
            % discrete threshold order used inside the solid-state rate.
            eg_tilde = (2 / pi) * eg_j ./ sqrt(max(gamma1, realmin('double'))) .* e2;
            x = eg_tilde ./ (hbar * omega);
            nu_cont = max(x + 1, 1);
            nu_tol = max(1024 * eps(max(abs(nu_cont), 1.0)), 1e-12);
            nu_int = max(floor(nu_cont + nu_tol), 1);

            % The ratio term carries the tunneling exponent scale that
            % appears in both the Q-series weights and the final rate.
            ratio = (k1 - e1) ./ max(e2, realmin('double'));
            ratio = max(ratio, 0.0);
        end

        function [w_2, nu_cont, soft_warn_state, nu_int] = keldysh_solid_interband_rate( ...
                gamma, omega, eg_j, mred_kg, hbar, use_solid_state_keldysh_flag, ...
                use_interference_corrected_rate_flag, soft_warn_state)
        %KELDYSH_SOLID_INTERBAND_RATE Solid-state interband Keldysh rate law.
        % Inputs are the Keldysh gamma parameter and the material/frequency
        % scalars needed by the solid-state interband formula.
        %
        % Outputs:
        %   w_2     : solid-state volumetric interband rate from the chosen
        %             Keldysh branch; this is distinct from the later
        %             normalized runtime per-neutral W_ion(I) law used for
        %             matched accounting and sigma_K,eff/beta_K,eff
        %             diagnostic surrogates
        %   nu_cont : continuous threshold Eg_tilde/(hbar*omega) + 1
        %   soft_warn_state : updated Keldysh warning ledger after any
        %             branch-specific clamp, convergence, or rate-build
        %             warning handling in this call; this is threaded state
        %             rather than a derived threshold-order output
        %   nu_int  : discrete threshold order floor(nu_cont + nu_tol)
        %             using the same near-integer-stabilized threshold rule
        %             that enters the solid-state rate law; the default
        %             K_display scalar is chosen separately by evaluating
        %             that same rule at the selected reference intensity
        %
        % Math outline:
        % - gamma is mapped to the standard elliptic-integral parameters
        %   gamma1 = gamma^2 / (1 + gamma^2)
        %   gamma2 = 1 / (1 + gamma^2)
        % - those feed K(m) and E(m), which set the effective gap
        %   Eg_tilde, the photon-order threshold nu, and the tunneling
        %   exponent ratio
        % - when the upstream lookup builder reconstructs gamma from
        %   intensity, it uses the in-medium field amplitude
        %   E = sqrt(2 I / (n_fund*ep0*c)); that normalization is an
        %   implementation-side intensity-to-field convention rather than a
        %   separate solid-rate branch choice
        % - the default branch keeps the original transparent-solid
        %   Keldysh Q-series of Keldysh (1965) as the legacy reproduction
        %   path, evaluated by keldysh_original_qseries_rate_local(...)
        % - the optional corrected branch replaces that with the
        %   interference-corrected transparent-solid cKLD channel sum of
        %   Shcheblanov et al. (Phys. Rev. A 96, 063410, 2017), written in
        %   the Kane-band two-band notation of E. O. Kane,
        %   J. Phys. Chem. Solids 1, 249-261 (1957), and evaluated by
        %   keldysh_interference_corrected_ckld_rate_local(...)
        % - the full calling form passes
        %   use_interference_corrected_rate_flag, soft_warn_state as
        %   inputs 7-8; a seven-input shorthand is also supported, where
        %   input 7 may be [] or a struct soft_warn_state and the corrected
        %   branch flag then defaults to false

            nu_cont = NaN;
            nu_int = NaN;
            if nargin < 6 || isempty(use_solid_state_keldysh_flag)
                use_solid_state_keldysh_flag = true;
            end
            if nargin < 7
                use_interference_corrected_rate_flag = false;
            end
            if nargin < 8
                if isstruct(use_interference_corrected_rate_flag) || ...
                        isempty(use_interference_corrected_rate_flag)
                    soft_warn_state = use_interference_corrected_rate_flag;
                    use_interference_corrected_rate_flag = false;
                else
                    soft_warn_state = struct();
                end
            end
            if isempty(soft_warn_state)
                soft_warn_state = struct();
            elseif ~isstruct(soft_warn_state)
                error('CerUPP:Keldysh:InvalidSoftWarnState', ...
                    'soft_warn_state must be a struct or empty ([]).');
            end
            soft_warn_state = struct_utils.ensure_warned_keys_map(soft_warn_state);
            use_interference_corrected_rate_flag = logical( ...
                use_interference_corrected_rate_flag);
            plasma_setup_support.require_supported_solid_keldysh_convention_local( ...
                use_solid_state_keldysh_flag, 'keldysh_solid_interband_rate');
            gamma_shape = size(gamma);
            gamma = double(gamma);
            if isempty(gamma)
                error('CerUPP:Keldysh:InvalidRateInput', ...
                    'keldysh_solid_interband_rate requires a nonempty gamma input.');
            end
            bad_gamma = ~isfinite(gamma) | (gamma <= 0);
            if any(bad_gamma(:)) || ~isscalar(omega) || ~isscalar(eg_j) || ...
                    ~isscalar(mred_kg) || ~isscalar(hbar) || ...
                    ~isfinite(omega) || ~isfinite(eg_j) || ~isfinite(mred_kg) || ~isfinite(hbar) || ...
                    omega <= 0 || eg_j <= 0 || mred_kg <= 0 || hbar <= 0
                bad_gamma_idx = find(bad_gamma, 1, 'first');
                if isempty(bad_gamma_idx)
                    bad_gamma_idx = 0;
                end
                error('CerUPP:Keldysh:InvalidRateInput', ...
                    ['keldysh_solid_interband_rate requires finite positive gamma samples and ', ...
                     'finite positive scalar omega/Eg_J/mred_kg/hbar; bad_gamma_idx=%d ', ...
                     'omega=%g Eg_J=%g mred_kg=%g hbar=%g.'], ...
                    bad_gamma_idx, double(omega), double(eg_j), double(mred_kg), double(hbar));
            end

            omega = double(omega);
            eg_j = double(eg_j);
            mred_kg = double(mred_kg);
            hbar = double(hbar);
            [gamma, x, nu_cont, nu_int, ratio, gamma1, k2, e2] = ...
                plasma_keldysh_setup.solid_state_threshold_terms_local( ...
                gamma, omega, eg_j, hbar);

            % Both private solid-state rate kernels return the sampled rate
            % together with the updated soft_warn_state ledger.
            if use_interference_corrected_rate_flag
                nonfinite_rate_error_id = ...
                    'CerUPP:Keldysh:CorrectedRateNonFinite';
                negative_rate_error_id = ...
                    'CerUPP:Keldysh:CorrectedRateNegative';
                rate_branch_label = 'corrected cKLD branch';
                [w_2, soft_warn_state] = ...
                    plasma_keldysh_setup.keldysh_interference_corrected_ckld_rate_local( ...
                    gamma, x, nu_int, ratio, gamma1, k2, e2, ...
                    omega, eg_j, mred_kg, hbar, soft_warn_state);
            else
                nonfinite_rate_error_id = ...
                    'CerUPP:Keldysh:LegacyRateNonFinite';
                negative_rate_error_id = ...
                    'CerUPP:Keldysh:LegacyRateNegative';
                rate_branch_label = 'legacy q-series branch';
                [w_2, soft_warn_state] = ...
                    plasma_keldysh_setup.keldysh_original_qseries_rate_local( ...
                    gamma, x, nu_int, ratio, gamma1, k2, e2, ...
                    omega, mred_kg, hbar, soft_warn_state);
            end
            if any(~isfinite(w_2(:)))
                bad_idx = find(~isfinite(w_2), 1, 'first');
                error(nonfinite_rate_error_id, ...
                    'Non-finite Keldysh rate W produced in the %s at gamma index %d.', ...
                    rate_branch_label, bad_idx);
            end
            if any(w_2(:) < 0)
                bad_idx = find(w_2 < 0, 1, 'first');
                error(negative_rate_error_id, ...
                    'Negative Keldysh rate W produced in the %s at gamma index %d.', ...
                    rate_branch_label, bad_idx);
            end
            w_2 = reshape(w_2, gamma_shape);
            nu_cont = reshape(nu_cont, gamma_shape);
            nu_int = reshape(nu_int, gamma_shape);
        end

        function [w_2, soft_warn_state] = keldysh_original_qseries_rate_local( ...
                gamma, x, nu_int, ratio, gamma1, k2, e2, ...
                omega, mred_kg, hbar, soft_warn_state)
        % Transparent-solid Keldysh Q-series branch from
        % L. V. Keldysh, Sov. Phys. JETP 20, 1307-1314 (1965), with
        % explicit Dawson-tail remainder control. Returns the volumetric
        % solid-state interband rate w_2, meaning the full solid-state
        % W_ion law before the later per-neutral normalization, together
        % with the updated soft_warn_state ledger for this branch.

            pref_q = sqrt(pi ./ (2 * max(k2, realmin('double'))));
            dawson_series_fast_nterm = 256;
            dawson_series_promoted_warning_cap = 8192;
            exp_underflow_cutoff = -740;
            daw_den_factor = 2.0;
            dawson_series_min_terms = 8;
            dawson_series_rel_tol = 1e-12;
            dawson_series_tail_min_arg = 6.0;
            dawson_upper_bound = plasma_keldysh_setup.keldysh_dawson_upper_bound_local();
            qsum = zeros(size(gamma));
            hit_max_terms = true(size(gamma));
            active_mask = true(size(gamma));
            converged_nterm = NaN(size(gamma));
            alpha_tail_full = pi .* max(ratio, realmin('double'));

            for nterm = 0:dawson_series_promoted_warning_cap
                if ~any(active_mask(:))
                    break;
                end
                active_idx = find(active_mask);
                expo_n = -pi * nterm .* ratio(active_idx);
                underflow_mask = expo_n < exp_underflow_cutoff;
                if any(underflow_mask)
                    idx_under = active_idx(underflow_mask);
                    hit_max_terms(idx_under) = false;
                    active_mask(idx_under) = false;
                    converged_nterm(idx_under) = nterm;
                end
                active_idx = active_idx(~underflow_mask);
                expo_n = expo_n(~underflow_mask);
                if isempty(active_idx)
                    continue;
                end

                arg_num = pi^2 .* max((2 .* nu_int(active_idx) - 2 .* x(active_idx) + nterm), 0.0);
                arg_den = daw_den_factor .* max(k2(active_idx) .* e2(active_idx), realmin('double'));
                daw_arg = sqrt(arg_num ./ arg_den);
                term = exp(expo_n) .* plasma_keldysh_setup.dawson_real(daw_arg);
                qsum(active_idx) = qsum(active_idx) + term;
                if nterm > dawson_series_min_terms
                    b_tail = max((2 .* nu_int(active_idx) - 2 .* x(active_idx)), 0.0);
                    arg_den_tail = daw_den_factor .* ...
                        max(k2(active_idx) .* e2(active_idx), realmin('double'));
                    tail_upper = plasma_keldysh_setup.keldysh_qseries_tail_upper_bound_local( ...
                        alpha_tail_full(active_idx), b_tail, arg_den_tail, ...
                        nterm + 1, dawson_series_tail_min_arg, ...
                        dawson_upper_bound, exp_underflow_cutoff);
                    converged_mask = tail_upper <= ...
                        dawson_series_rel_tol .* max(1.0, abs(qsum(active_idx)));
                    if any(converged_mask)
                        idx_conv = active_idx(converged_mask);
                        hit_max_terms(idx_conv) = false;
                        active_mask(idx_conv) = false;
                        converged_nterm(idx_conv) = nterm;
                    end
                end
            end
            if any(hit_max_terms(:))
                promoted_stop_nterm = plasma_keldysh_setup.keldysh_tail_extension_stop_nterm_local( ...
                    alpha_tail_full(hit_max_terms), ...
                    dawson_series_rel_tol .* max(1.0, abs(qsum(hit_max_terms))), ...
                    dawson_upper_bound ./ max(-expm1(-alpha_tail_full(hit_max_terms)), realmin('double')), ...
                    exp_underflow_cutoff, dawson_series_promoted_warning_cap);
                for nterm = (dawson_series_promoted_warning_cap + 1):promoted_stop_nterm
                    if ~any(active_mask(:))
                        break;
                    end
                    active_idx = find(active_mask);
                    expo_n = -pi * nterm .* ratio(active_idx);
                    underflow_mask = expo_n < exp_underflow_cutoff;
                    if any(underflow_mask)
                        idx_under = active_idx(underflow_mask);
                        hit_max_terms(idx_under) = false;
                        active_mask(idx_under) = false;
                        converged_nterm(idx_under) = nterm;
                    end
                    active_idx = active_idx(~underflow_mask);
                    expo_n = expo_n(~underflow_mask);
                    if isempty(active_idx)
                        continue;
                    end

                    arg_num = pi^2 .* max((2 .* nu_int(active_idx) - 2 .* x(active_idx) + nterm), 0.0);
                    arg_den = daw_den_factor .* max(k2(active_idx) .* e2(active_idx), realmin('double'));
                    daw_arg = sqrt(arg_num ./ arg_den);
                    term = exp(expo_n) .* plasma_keldysh_setup.dawson_real(daw_arg);
                    qsum(active_idx) = qsum(active_idx) + term;
                    b_tail = max((2 .* nu_int(active_idx) - 2 .* x(active_idx)), 0.0);
                    arg_den_tail = daw_den_factor .* ...
                        max(k2(active_idx) .* e2(active_idx), realmin('double'));
                    tail_upper = plasma_keldysh_setup.keldysh_qseries_tail_upper_bound_local( ...
                        alpha_tail_full(active_idx), b_tail, arg_den_tail, ...
                        nterm + 1, dawson_series_tail_min_arg, ...
                        dawson_upper_bound, exp_underflow_cutoff);
                    converged_mask = tail_upper <= ...
                        dawson_series_rel_tol .* max(1.0, abs(qsum(active_idx)));
                    if any(converged_mask)
                        idx_conv = active_idx(converged_mask);
                        hit_max_terms(idx_conv) = false;
                        active_mask(idx_conv) = false;
                        converged_nterm(idx_conv) = nterm;
                    end
                end
            else
                promoted_stop_nterm = dawson_series_promoted_warning_cap;
            end
            q = pref_q .* max(qsum, 0.0);
            pref = ((2 * omega) / (9 * pi)) .* ...
                (((mred_kg * omega) ./ (hbar .* ...
                sqrt(max(gamma1, realmin('double'))))).^(3/2));
            expo = max(-pi .* nu_int .* ratio, exp_underflow_cutoff);
            w_2 = pref .* q .* exp(expo);
            if any(hit_max_terms(:))
                tail_idx = find(hit_max_terms);
                b_tail = max((2 .* nu_int(tail_idx) - 2 .* x(tail_idx)), 0.0);
                arg_den_tail = daw_den_factor .* ...
                    max(k2(tail_idx) .* e2(tail_idx), realmin('double'));
                [tail_upper, tail_start_arg] = ...
                    plasma_keldysh_setup.keldysh_qseries_tail_upper_bound_local( ...
                    alpha_tail_full(tail_idx), b_tail, arg_den_tail, ...
                    promoted_stop_nterm + 1, ...
                    dawson_series_tail_min_arg, dawson_upper_bound, ...
                    exp_underflow_cutoff);
                tail_rel = tail_upper ./ max(1.0, abs(qsum(tail_idx)));
                [tail_rel_max, bad_local] = max(tail_rel);
                bad_idx = tail_idx(bad_local);
                error('CerUPP:Keldysh:QSeriesConvergenceUnresolved', ...
                    ['Keldysh Q-series still had a remainder upper bound above the requested tolerance after the ', ...
                     'contract-based tail extension through %d terms ', ...
                     '(tail_rel=%.3g, tail_arg=%.3g, gamma=%.3g, x=%.3g). ', ...
                     'Refusing to continue rather than install an underconverged W_ion(I) law.'], ...
                    promoted_stop_nterm, tail_rel_max, tail_start_arg(bad_local), ...
                    gamma(bad_idx), x(bad_idx));
            end
            extended_mask = converged_nterm > dawson_series_fast_nterm;
            if any(extended_mask(:))
                extended_terms = converged_nterm;
                extended_terms(~extended_mask) = -Inf;
                [max_nterm_used, warn_idx] = max(extended_terms);
                [soft_warn_state, ~] = warning_utils.cerupp_warn_once( ...
                    soft_warn_state, ...
                    'KELDYSH_QSERIES_EXTENDED_BUDGET', ...
                    'CerUPP:Keldysh:QSeriesExtendedBudget', ...
                    ['The solid-state Keldysh Q-series needed %d terms, which exceeded the ', ...
                     '%d-term fast-pass budget but still satisfied the explicit remainder bound ', ...
                     '(gamma=%.3g, x=%.3g, nu=%g, alpha_tail=%.3g).'], ...
                    max_nterm_used, dawson_series_fast_nterm, ...
                    gamma(warn_idx), x(warn_idx), nu_int(warn_idx), alpha_tail_full(warn_idx));
            end
        end

        function [w_2, soft_warn_state] = keldysh_interference_corrected_ckld_rate_local( ...
                gamma, x, nu_int, ratio, gamma1, k2, e2, ...
                omega, eg_j, mred_kg, hbar, soft_warn_state)
        % Interference-corrected transparent-solid cKLD channel sum from
        % N. S. Shcheblanov et al., Phys. Rev. A 96, 063410 (2017),
        % written in the Kane-band two-band notation of E. O. Kane,
        % J. Phys. Chem. Solids 1, 249-261 (1957). Returns the volumetric
        % solid-state interband rate w_2, meaning the full solid-state
        % W_ion law before the later per-neutral normalization, together
        % with the updated soft_warn_state ledger for this branch.

            exp_underflow_cutoff = -740;
            corrected_series_legacy_cap = 512;
            corrected_series_fast_max_nterm = 8192;
            corrected_series_promoted_warning_cap = 65536;
            corrected_series_min_terms = 8;
            corrected_series_rel_tol = 1e-12;
            corrected_phi_upper_bound = ...
                plasma_keldysh_setup.keldysh_corrected_phi_upper_bound_local();
            qsum = zeros(size(gamma));
            hit_max_terms = true(size(gamma));
            active_mask = true(size(gamma));
            converged_nterm = NaN(size(gamma));
            corrected_phi_adaptive_fallback_count = 0;
            corrected_phi_adaptive_fallback_max_v_hi = NaN;
            alpha_corr = pi .* ratio;
            if any(~isfinite(alpha_corr(:)) | (alpha_corr(:) <= 0))
                bad_idx = find(~isfinite(alpha_corr(:)) | (alpha_corr(:) <= 0), 1, 'first');
                error('CerUPP:Keldysh:CorrectedSeriesAlphaInvalid', ...
                    ['Interference-corrected Keldysh channel sum requires finite positive alpha_corr=pi*ratio. ' ...
                     'Got alpha_corr=%.3g at index %d (gamma=%.3g, ratio=%.3g).'], ...
                    alpha_corr(bad_idx), bad_idx, gamma(bad_idx), ratio(bad_idx));
            end
            tail_denom = max(-expm1(-alpha_corr), realmin('double'));
            beta_corr = pi^2 ./ (2 .* max(k2 .* e2, realmin('double')));
            gamma2_mod = sqrt(max(gamma1, realmin('double')));
            acot_arg = (1 ./ (2 .* gamma)) - (gamma ./ 2);
            a_phase = sqrt((eg_j .* k2) ./ ...
                (2 .* pi .* hbar .* omega .* gamma2_mod)) .* atan2(1, acot_arg);
            pref_q = sqrt(pi ./ (2 .* max(k2, realmin('double'))));
            pref = ((4 * omega) / (9 * pi)) .* ...
                (((mred_kg * omega) ./ (hbar .* gamma2_mod)).^(3/2));

            for nterm = 0:corrected_series_fast_max_nterm
                if ~any(active_mask(:))
                    break;
                end
                active_idx = find(active_mask);
                expo_n = -alpha_corr(active_idx) .* nterm;
                underflow_mask = expo_n < exp_underflow_cutoff;
                if any(underflow_mask)
                    idx_under = active_idx(underflow_mask);
                    hit_max_terms(idx_under) = false;
                    active_mask(idx_under) = false;
                end
                active_idx = active_idx(~underflow_mask);
                expo_n = expo_n(~underflow_mask);
                if isempty(active_idx)
                    continue;
                end

                l_curr = nu_int(active_idx) + nterm;
                z_arg = sqrt(max(beta_corr(active_idx) .* ...
                    max(l_curr - x(active_idx), 0.0), 0.0));
                [phi_term, phi_meta] = ...
                    plasma_keldysh_setup.keldysh_corrected_kane_phi_local( ...
                    z_arg, a_phase(active_idx), mod(l_curr, 2));
                corrected_phi_adaptive_fallback_count = ...
                    corrected_phi_adaptive_fallback_count + ...
                    double(phi_meta.adaptive_fallback_count);
                if isfinite(phi_meta.adaptive_fallback_max_v_hi)
                    if ~isfinite(corrected_phi_adaptive_fallback_max_v_hi)
                        corrected_phi_adaptive_fallback_max_v_hi = ...
                            double(phi_meta.adaptive_fallback_max_v_hi);
                    else
                        corrected_phi_adaptive_fallback_max_v_hi = max( ...
                            corrected_phi_adaptive_fallback_max_v_hi, ...
                            double(phi_meta.adaptive_fallback_max_v_hi));
                    end
                end
                term = exp(expo_n) .* phi_term;
                qsum(active_idx) = qsum(active_idx) + term;
                if nterm > corrected_series_min_terms
                    tail_upper = plasma_keldysh_setup.keldysh_corrected_series_tail_upper_bound_local( ...
                        alpha_corr(active_idx), tail_denom(active_idx), nterm + 1, ...
                        corrected_phi_upper_bound, exp_underflow_cutoff);
                    converged_mask = tail_upper <= ...
                        corrected_series_rel_tol .* max(1.0, abs(qsum(active_idx)));
                    if any(converged_mask)
                        idx_conv = active_idx(converged_mask);
                        hit_max_terms(idx_conv) = false;
                        active_mask(idx_conv) = false;
                        converged_nterm(idx_conv) = nterm;
                    end
                end
            end
            if any(hit_max_terms(:))
                promoted_stop_nterm = plasma_keldysh_setup.keldysh_tail_extension_stop_nterm_local( ...
                    alpha_corr(hit_max_terms), ...
                    corrected_series_rel_tol .* max(1.0, abs(qsum(hit_max_terms))), ...
                    corrected_phi_upper_bound ./ max(tail_denom(hit_max_terms), realmin('double')), ...
                    exp_underflow_cutoff, corrected_series_promoted_warning_cap);
                for nterm = (corrected_series_fast_max_nterm + 1):promoted_stop_nterm
                    if ~any(active_mask(:))
                        break;
                    end
                    active_idx = find(active_mask);
                    expo_n = -alpha_corr(active_idx) .* nterm;
                    underflow_mask = expo_n < exp_underflow_cutoff;
                    if any(underflow_mask)
                        idx_under = active_idx(underflow_mask);
                        hit_max_terms(idx_under) = false;
                        active_mask(idx_under) = false;
                    end
                    active_idx = active_idx(~underflow_mask);
                    expo_n = expo_n(~underflow_mask);
                    if isempty(active_idx)
                        continue;
                    end

                    l_curr = nu_int(active_idx) + nterm;
                    z_arg = sqrt(max(beta_corr(active_idx) .* ...
                        max(l_curr - x(active_idx), 0.0), 0.0));
                    [phi_term, phi_meta] = ...
                        plasma_keldysh_setup.keldysh_corrected_kane_phi_local( ...
                        z_arg, a_phase(active_idx), mod(l_curr, 2));
                    corrected_phi_adaptive_fallback_count = ...
                        corrected_phi_adaptive_fallback_count + ...
                        double(phi_meta.adaptive_fallback_count);
                    if isfinite(phi_meta.adaptive_fallback_max_v_hi)
                        if ~isfinite(corrected_phi_adaptive_fallback_max_v_hi)
                            corrected_phi_adaptive_fallback_max_v_hi = ...
                                double(phi_meta.adaptive_fallback_max_v_hi);
                        else
                            corrected_phi_adaptive_fallback_max_v_hi = max( ...
                                corrected_phi_adaptive_fallback_max_v_hi, ...
                                double(phi_meta.adaptive_fallback_max_v_hi));
                        end
                    end
                    term = exp(expo_n) .* phi_term;
                    qsum(active_idx) = qsum(active_idx) + term;
                    tail_upper = plasma_keldysh_setup.keldysh_corrected_series_tail_upper_bound_local( ...
                        alpha_corr(active_idx), tail_denom(active_idx), nterm + 1, ...
                        corrected_phi_upper_bound, exp_underflow_cutoff);
                    converged_mask = tail_upper <= ...
                        corrected_series_rel_tol .* max(1.0, abs(qsum(active_idx)));
                    if any(converged_mask)
                        idx_conv = active_idx(converged_mask);
                        hit_max_terms(idx_conv) = false;
                        active_mask(idx_conv) = false;
                        converged_nterm(idx_conv) = nterm;
                    end
                end
            else
                promoted_stop_nterm = corrected_series_promoted_warning_cap;
            end
            q = pref_q .* max(qsum, 0.0);
            expo = max(-alpha_corr .* nu_int, exp_underflow_cutoff);
            w_2 = pref .* q .* exp(expo);
            if any(hit_max_terms(:))
                bad_idx = find(hit_max_terms, 1, 'first');
                error('CerUPP:Keldysh:CorrectedSeriesConvergenceUnresolved', ...
                    ['The interference-corrected Kane Keldysh channel sum still had a geometric ', ...
                     'remainder upper bound above the requested tolerance after the contract-based ', ...
                     'tail extension through %d terms (first-pass budget %d terms) ', ...
                     '(gamma=%.3g, x=%.3g, nu=%g, alpha_corr=%.3g).'], ...
                    promoted_stop_nterm, corrected_series_fast_max_nterm, ...
                    gamma(bad_idx), ...
                    x(bad_idx), nu_int(bad_idx), alpha_corr(bad_idx));
            end
            if any(converged_nterm(:) > corrected_series_legacy_cap)
                [max_nterm_used, warn_idx] = max(converged_nterm);
                if max_nterm_used > corrected_series_fast_max_nterm
                    [soft_warn_state, ~] = warning_utils.cerupp_warn_once( ...
                        soft_warn_state, ...
                        'KELDYSH_CORRECTED_SERIES_EXTENDED_BUDGET', ...
                        'CerUPP:Keldysh:CorrectedSeriesExtendedBudget', ...
                        ['The interference-corrected Kane Keldysh channel sum needed %d terms, which exceeds the ', ...
                         '512-term early-warning threshold and the %d-term first-pass budget but still satisfied ', ...
                         'the corrected remainder bound (gamma=%.3g, x=%.3g, nu=%g, alpha_corr=%.3g).'], ...
                        max_nterm_used, corrected_series_fast_max_nterm, ...
                        gamma(warn_idx), x(warn_idx), nu_int(warn_idx), alpha_corr(warn_idx));
                else
                    [soft_warn_state, ~] = warning_utils.cerupp_warn_once( ...
                        soft_warn_state, ...
                        'KELDYSH_CORRECTED_SERIES_EXTENDED_BUDGET', ...
                        'CerUPP:Keldysh:CorrectedSeriesExtendedBudget', ...
                        ['The interference-corrected Kane Keldysh channel sum needed %d terms, which exceeds the ', ...
                         '512-term early-warning threshold but still satisfied the corrected remainder bound ', ...
                         '(gamma=%.3g, x=%.3g, nu=%g, alpha_corr=%.3g).'], ...
                        max_nterm_used, gamma(warn_idx), x(warn_idx), nu_int(warn_idx), alpha_corr(warn_idx));
                end
            end
            if corrected_phi_adaptive_fallback_count > 0
                [soft_warn_state, ~] = warning_utils.cerupp_warn_once( ...
                    soft_warn_state, ...
                    'KELDYSH_CORRECTED_PHI_ADAPTIVE_FALLBACK_USED', ...
                    'CerUPP:Keldysh:CorrectedPhiAdaptiveFallbackUsed', ...
                    ['The interference-corrected Kane phi_l quadrature promoted %d sampled points ', ...
                     'from the Simpson ladder to the adaptive integral fallback ', ...
                     '(largest fallback v_hi=%.3g). The installed W_ion(I) law therefore used ', ...
                     'mixed phi_l quadrature paths during this build.'], ...
                    corrected_phi_adaptive_fallback_count, ...
                    corrected_phi_adaptive_fallback_max_v_hi);
            end
            if any(~isfinite(w_2(:)))
                bad_idx = find(~isfinite(w_2), 1, 'first');
                error('CerUPP:Keldysh:CorrectedRateNonFinite', ...
                    'Non-finite interference-corrected Keldysh rate at gamma index %d.', ...
                    bad_idx);
            end
        end

        function [phi_term, phi_meta] = keldysh_corrected_kane_phi_local(z_arg, a_phase, parity_mod2)
        % Evaluate the corrected Kane-band phi_l(z) integral for one vector.
        % The y->v endpoint transform keeps the strong e^(y^2-z^2) weight
        % numerically tame on [0, min(2*z^2, v_cap)], and the Simpson panel
        % count is refined until successive estimates agree within the
        % requested mixed relative/absolute tolerance plus the explicit
        % truncated-tail bound.

            z_arg = max(double(z_arg(:)), 0.0);
            a_phase = double(a_phase(:));
            parity_mod2 = mod(round(double(parity_mod2(:))), 2);
            if ~(numel(z_arg) == numel(a_phase) && numel(z_arg) == numel(parity_mod2))
                error('CerUPP:Keldysh:CorrectedPhiSizeMismatch', ...
                    'Corrected Keldysh phi_l inputs must have matching lengths.');
            end
            phi_term = zeros(size(z_arg));
            phi_meta = struct( ...
                'adaptive_fallback_count', 0, ...
                'adaptive_fallback_max_v_hi', NaN);
            active_mask = z_arg > 0;
            if ~any(active_mask)
                return;
            end

            z_active = z_arg(active_mask);
            a_active = a_phase(active_mask);
            parity_active = parity_mod2(active_mask);
            v_cap = 80.0;
            phi_rel_tol = 1e-11;
            phi_abs_tol = 1e-10;
            z_safe = max(z_active, realmin('double'));
            v_upper_full = 2 .* (z_active .^ 2);
            v_hi = min(v_upper_full, v_cap);
            truncated_tail_upper = zeros(size(z_active));
            truncated_mask = (v_upper_full > v_cap);
            if any(truncated_mask)
                truncated_tail_upper(truncated_mask) = ...
                    exp(-0.5 .* v_cap) ./ z_safe(truncated_mask);
            end
            nseg_ladder = [32, 64, 128, 256, 512, 1024, 2048, 4096];
            phi_prev = [];
            phi_active = NaN(size(z_active));
            unresolved_mask = true(size(z_active));
            for kk = 1:numel(nseg_ladder)
                active_idx = find(unresolved_mask);
                if isempty(active_idx)
                    break;
                end
                phi_curr = plasma_keldysh_setup.keldysh_corrected_phi_eval_local( ...
                    z_active(active_idx), a_active(active_idx), parity_active(active_idx), ...
                    v_hi(active_idx), nseg_ladder(kk));
                if any(~isfinite(phi_curr))
                    bad_local = find(~isfinite(phi_curr), 1, 'first');
                    bad_idx = active_idx(bad_local);
                    error('CerUPP:Keldysh:CorrectedPhiNonFinite', ...
                        ['Non-finite phi_l value in interference-corrected Keldysh integral ', ...
                         'at z=%.3g, a_phase=%.3g, parity=%d, nseg=%d.'], ...
                        z_active(bad_idx), a_active(bad_idx), parity_active(bad_idx), ...
                        nseg_ladder(kk));
                end
                if isempty(phi_prev)
                    phi_prev = NaN(size(z_active));
                    phi_prev(active_idx) = phi_curr;
                    continue;
                end
                err_est = abs(phi_curr - phi_prev(active_idx)) + truncated_tail_upper(active_idx);
                tol = phi_abs_tol + phi_rel_tol .* abs(phi_curr);
                converged_mask = (err_est <= tol);
                if any(converged_mask)
                    idx_conv = active_idx(converged_mask);
                    phi_active(idx_conv) = max(real(phi_curr(converged_mask)), 0.0);
                    unresolved_mask(idx_conv) = false;
                end
                if any(~converged_mask)
                    idx_keep = active_idx(~converged_mask);
                    phi_prev(idx_keep) = phi_curr(~converged_mask);
                end
            end
            if any(unresolved_mask)
                unresolved_idx = find(unresolved_mask);
                phi_meta.adaptive_fallback_count = numel(unresolved_idx);
                phi_meta.adaptive_fallback_max_v_hi = max(v_hi(unresolved_idx));
                adaptive_fail_mask = false(size(z_active));
                first_fail_id = '';
                first_fail_msg = '';
                first_fail_exception = [];
                for jj = 1:numel(unresolved_idx)
                    idx_unres = unresolved_idx(jj);
                    try
                        phi_active(idx_unres) = ...
                            plasma_keldysh_setup.keldysh_corrected_phi_eval_with_tail_guard_local( ...
                            z_active(idx_unres), a_active(idx_unres), parity_active(idx_unres), ...
                            v_hi(idx_unres), v_upper_full(idx_unres), phi_rel_tol, phi_abs_tol);
                        unresolved_mask(idx_unres) = false;
                    catch me
                        adaptive_fail_mask(idx_unres) = true;
                        if isempty(first_fail_id)
                            first_fail_id = char(me.identifier);
                            first_fail_msg = char(me.message);
                            first_fail_exception = me;
                        end
                    end
                end
                if any(adaptive_fail_mask)
                    fail_idx = find(adaptive_fail_mask);
                    bad_idx = fail_idx(1);
                    wrapped = MException('CerUPP:Keldysh:CorrectedPhiUnresolved', ...
                        ['Interference-corrected phi_l fallback left %d unresolved sampled points ', ...
                         'after the adaptive quadrature path failed there ', ...
                         '(first unresolved z=%.3g, a_phase=%.3g, parity=%d). ', ...
                         'First fallback failure: %s: %s'], ...
                        numel(fail_idx), z_active(bad_idx), a_active(bad_idx), ...
                        parity_active(bad_idx), first_fail_id, first_fail_msg);
                    if ~isempty(first_fail_exception)
                        wrapped = addCause(wrapped, first_fail_exception);
                    end
                    throwAsCaller(wrapped);
                end
            end
            phi_term(active_mask) = max(real(phi_active), 0.0);
        end

        function phi_eval = keldysh_corrected_phi_eval_local(z_arg, a_phase, parity_mod2, v_hi, nseg)
        % One Simpson estimate for the transformed corrected phi_l integral.

            [s_nodes, s_weights] = plasma_keldysh_setup.keldysh_unit_interval_simpson_rule_local(nseg);
            z_safe = max(double(z_arg(:)), realmin('double'));
            a_phase = double(a_phase(:));
            parity_mod2 = mod(round(double(parity_mod2(:))), 2);
            v_hi = double(v_hi(:));
            phase0 = (pi / 2) .* parity_mod2;
            az_term = a_phase .* z_safe;
            phase_slope = (a_phase .* v_hi) ./ (2 .* z_safe);
            expo_quad = -v_hi .* s_nodes + ((v_hi .^ 2) ./ (4 .* (z_safe .^ 2))) .* (s_nodes .^ 2);
            integrand = sin(phase0 + az_term - phase_slope .* s_nodes) .^ 2 .* exp(expo_quad);
            phi_eval = (v_hi ./ (2 .* z_safe)) .* (integrand * s_weights.');
        end

        function phi_eval = keldysh_corrected_phi_eval_adaptive_local( ...
                z_arg, a_phase, parity_mod2, v_hi, phi_rel_tol, phi_abs_tol)
        % Adaptive fallback for corrected phi_l points the Simpson ladder did not settle.

            z_safe = max(double(z_arg), realmin('double'));
            a_phase = double(a_phase);
            parity_mod2 = mod(round(double(parity_mod2)), 2);
            v_hi = double(v_hi);
            if ~(isfinite(z_safe) && isfinite(a_phase) && isfinite(v_hi))
                error('CerUPP:Keldysh:CorrectedPhiAdaptiveInvalidInput', ...
                    'Adaptive corrected phi_l fallback needs finite z, a_phase, and v_hi.');
            end
            if v_hi <= 0
                phi_eval = 0.0;
                return;
            end
            phase0 = (pi / 2) .* parity_mod2;
            az_term = a_phase .* z_safe;
            phase_slope = (a_phase .* v_hi) ./ (2 .* z_safe);
            integrand = @(s) sin(phase0 + az_term - phase_slope .* s) .^ 2 .* ...
                exp(-v_hi .* s + ((v_hi .^ 2) ./ (4 .* (z_safe .^ 2))) .* (s .^ 2));
            try
                phi_eval = (v_hi ./ (2 .* z_safe)) .* integral( ...
                    integrand, 0, 1, 'ArrayValued', true, ...
                    'RelTol', phi_rel_tol, 'AbsTol', phi_abs_tol);
            catch me
                wrapped = MException('CerUPP:Keldysh:CorrectedPhiUnresolved', ...
                    ['Interference-corrected phi_l quadrature did not resolve through the ', ...
                     'adaptive fallback (z=%.3g, a_phase=%.3g, parity=%d, v_hi=%.3g). ', ...
                     'MATLAB said: %s'], ...
                    z_safe, a_phase, parity_mod2, v_hi, me.message);
                wrapped = addCause(wrapped, me);
                throwAsCaller(wrapped);
            end
            if ~isfinite(phi_eval)
                error('CerUPP:Keldysh:CorrectedPhiNonFinite', ...
                    ['Adaptive corrected phi_l fallback returned a non-finite value ', ...
                     '(z=%.3g, a_phase=%.3g, parity=%d, v_hi=%.3g).'], ...
                    z_safe, a_phase, parity_mod2, v_hi);
            end
            phi_eval = max(real(phi_eval), 0.0);
        end

        function phi_eval = keldysh_corrected_phi_eval_with_tail_guard_local( ...
                z_arg, a_phase, parity_mod2, v_hi, v_upper_full, phi_rel_tol, phi_abs_tol)
        % Adaptive corrected phi_l fallback with the same omitted-tail acceptance
        % contract used by the main Simpson ladder.

            z_safe = max(double(z_arg), realmin('double'));
            v_try = double(v_hi);
            v_full = double(v_upper_full);
            tail_upper = Inf;
            tol = Inf;
            while true
                phi_eval = plasma_keldysh_setup.keldysh_corrected_phi_eval_adaptive_local( ...
                    z_safe, a_phase, parity_mod2, v_try, phi_rel_tol, phi_abs_tol);
                tail_upper = 0.0;
                if v_full > v_try
                    tail_upper = exp(-0.5 .* v_try) ./ z_safe;
                end
                tol = phi_abs_tol + phi_rel_tol .* abs(phi_eval);
                if (tail_upper <= tol) || ~(v_full > v_try)
                    break;
                end
                v_next = min(v_full, max(2.0 .* v_try, v_try + 16.0));
                if ~(v_next > v_try)
                    break;
                end
                v_try = v_next;
            end
            if tail_upper > tol
                error('CerUPP:Keldysh:CorrectedPhiTailUnresolved', ...
                    ['Interference-corrected phi_l fallback still left an omitted-tail bound above ', ...
                     'tolerance (z=%.3g, a_phase=%.3g, parity=%d, v_hi=%.3g, v_full=%.3g, ', ...
                     'tail_upper=%.3g, tol=%.3g).'], ...
                    z_safe, double(a_phase), parity_mod2, v_try, v_full, tail_upper, tol);
            end
        end

        function [t_nodes, t_weights] = keldysh_unit_interval_simpson_rule_local(nseg)
        % Simpson rule on [0,1] for the transformed corrected phi_l integral.

            persistent last_nseg t_nodes_p t_weights_p
            if isempty(last_nseg) || isempty(t_nodes_p) || isempty(t_weights_p) || (last_nseg ~= nseg)
                if ~isscalar(nseg) || ~isfinite(nseg) || (nseg < 2) || mod(nseg, 2) ~= 0
                    error('CerUPP:Keldysh:InvalidSimpsonSegments', ...
                        'Simpson rule requires an even finite nseg >= 2; got %g.', nseg);
                end
                h = 1 / nseg;
                t_nodes_p = linspace(0, 1, nseg + 1);
                t_weights_p = ones(1, nseg + 1);
                t_weights_p(2:2:end-1) = 4;
                t_weights_p(3:2:end-2) = 2;
                t_weights_p = t_weights_p .* (h / 3);
                last_nseg = nseg;
            end
            t_nodes = t_nodes_p;
            t_weights = t_weights_p;
        end

        function tail_upper = keldysh_corrected_series_tail_upper_bound_local( ...
                alpha_corr, tail_denom, tail_start_nterm, corrected_phi_upper_bound, exp_underflow_cutoff)
        % Geometric remainder upper bound using phi_l(z) <= max Dawson(z).

            tail_start_nterm = double(tail_start_nterm);
            tail_expo = -double(alpha_corr) .* tail_start_nterm;
            tail_upper = zeros(size(tail_expo));
            active_mask = tail_expo > exp_underflow_cutoff;
            if any(active_mask(:))
                tail_upper(active_mask) = corrected_phi_upper_bound .* exp(tail_expo(active_mask)) ./ ...
                    max(double(tail_denom(active_mask)), realmin('double'));
            end
        end

        function stop_nterm = keldysh_tail_extension_stop_nterm_local( ...
                alpha_tail, tail_target, tail_prefactor, exp_underflow_cutoff, current_stop_nterm)
        % Return the last nterm needed so the geometric tail contract, not
        % a fixed ceiling, owns the promoted summation stop.

            alpha_tail = max(double(alpha_tail(:)), realmin('double'));
            tail_target = max(double(tail_target(:)), realmin('double'));
            tail_prefactor = max(double(tail_prefactor(:)), realmin('double'));
            required_start_nterm = ceil(max(-log(tail_target ./ tail_prefactor) ./ alpha_tail, 0.0));
            underflow_start_nterm = ceil((-double(exp_underflow_cutoff)) ./ alpha_tail);
            required_stop_nterm = min(required_start_nterm, underflow_start_nterm) - 1;
            required_stop_nterm = max(required_stop_nterm, 0.0);
            stop_nterm = max(double(current_stop_nterm), max(required_stop_nterm));
        end

        function [tail_upper, tail_start_arg] = keldysh_qseries_tail_upper_bound_local( ...
                alpha_tail, b_tail, arg_den_tail, tail_start_nterm, ...
                tail_min_arg, dawson_upper_bound, exp_underflow_cutoff)
        % Rigorous Q-series remainder upper bound from a geometric Dawson
        % cap. Keep this acceptance path on the proven bound only; the
        % large-argument asymptotic integral is not used to relax it.

            alpha_tail = max(double(alpha_tail), realmin('double'));
            b_tail = max(double(b_tail), 0.0);
            arg_den_tail = max(double(arg_den_tail), realmin('double'));
            tail_start_nterm = double(tail_start_nterm);
            tail_start_arg = sqrt(pi^2 .* ...
                max((b_tail + tail_start_nterm), 0.0) ./ arg_den_tail);
            tail_denom = max(-expm1(-alpha_tail), realmin('double'));
            tail_expo = -alpha_tail .* tail_start_nterm;
            tail_upper = zeros(size(tail_expo));
            active_mask = tail_expo > exp_underflow_cutoff;
            if any(active_mask(:))
                tail_upper(active_mask) = dawson_upper_bound .* ...
                    exp(tail_expo(active_mask)) ./ tail_denom(active_mask);
            end
            tail_upper(~isfinite(tail_upper)) = Inf;
        end

        function dawson_upper_bound = keldysh_dawson_upper_bound_local()
        % Global max_{x>=0} Dawson(x), used as one scalar cap in the
        % Q-series remainder bound. This is a numerically precomputed
        % property of Dawson's integral, not a material parameter.

            dawson_upper_bound = 0.5410442246351819;
        end

        function phi_upper_bound = keldysh_corrected_phi_upper_bound_local()
        % Uniform scalar bound from phi_l(z) <= Dawson(z) <= max_z Dawson(z).

            phi_upper_bound = plasma_keldysh_setup.keldysh_dawson_upper_bound_local();
        end

        function i_grid = build_log_grid(i_start, i_end, npts)
        %BUILD_LOG_GRID Build one positive log-spaced intensity grid.
        % Used by the LUT builder for both the wide coarse sweep and the
        % denser ROI sweep around the chosen seed intensity.

            i_start = double(i_start);
            i_end = double(i_end);
            npts = double(npts);
            if ~isfinite(npts) || (npts < 2) || (npts ~= floor(npts))
                error('CerUPP:LogGridBadCount', ...
                    'npts must be a finite integer >= 2, got %g.', npts);
            end
            if ~isfinite(i_start) || ~(i_start > 0)
                error('CerUPP:LogGridBadStart', ...
                    'I_start must be finite and > 0, got %g.', i_start);
            end
            if ~isfinite(i_end) || ~(i_end > 0)
                error('CerUPP:LogGridBadEnd', ...
                    'I_end must be finite and > 0, got %g.', i_end);
            end
            if i_end < i_start
                error('CerUPP:LogGridEndBeforeStart', ...
                    'I_end (%g) must be >= I_start (%g).', i_end, i_start);
            end
            if abs(log10(i_end) - log10(i_start)) < 1e-14
                error('CerUPP:LogGridZeroSpan', ...
                    ['I_end (%g) must be strictly larger than I_start (%g) so the runtime ', ...
                     'Keldysh LUT has distinct intensity samples.'], ...
                    i_end, i_start);
            end
            i_grid = logspace(log10(i_start), log10(i_end), npts).';
        end

        function [sigma_k_eff, beta_k_eff] = compute_keldysh_sigma_beta_from_w( ...
                w_lookup_sinv, i_lookup_wm2, k_eff_single, depletion_energy_j, rho_nt_keldysh_norm_m3)
        %COMPUTE_KELDYSH_SIGMA_BETA_FROM_W Build diagnostic surrogates from W(I).
        % These do not replace the dynamic W(I) law used at runtime. They
        % are derived diagnostic curves built from one chosen scalar
        % diagnostic exponent:
        %   sigma_K,eff(I) = W(I) / I^K_display
        %   beta_K,eff(I)  = depletion_energy_j * rho_nt_keldysh_norm_m3 * sigma_K,eff(I)
        % so the exported matched-Keldysh beta diagnostic stays on the
        % same depletion-energy convention as the applied matched loss
        % law, using the caller-supplied depletion-energy scalar.
        % In the locked-threshold default that scalar can equal Ui_J, but
        % this helper treats it as the matched bookkeeping energy scalar
        % chosen upstream. rho_nt_keldysh_norm_m3 is the Keldysh-
        % normalization density behind this matched diagnostic and may
        % differ from the physical neutral density in advanced branches.
        % Bins where the surrogate remap loses finite meaning, or where
        % the sampled W(I) surface is materially complex or materially
        % negative, are left as NaN. Tiny roundoff-scale imaginary
        % leakage and tiny negative real leakage inside the local
        % tolerance are clipped to zero before this
        % diagnostic-only remap is formed.

            i_raw = double(i_lookup_wm2);
            i_safe = nan(size(i_raw));
            positive_i_mask = isfinite(i_raw) & (i_raw > 0);
            i_safe(positive_i_mask) = max(i_raw(positive_i_mask), realmin('double'));
            w_raw = double(w_lookup_sinv);
            w_real = real(w_raw);
            w_imag = imag(w_raw);
            w_tol = 32 .* eps(max(max(abs(w_real), abs(w_imag)), 1));
            valid_w_mask = isfinite(w_real) & isfinite(w_imag) & ...
                (abs(w_imag) <= w_tol) & (w_real >= -w_tol);
            w_safe = nan(size(w_real));
            w_safe(valid_w_mask) = max(w_real(valid_w_mask), 0);
            kdyn_d = double(k_eff_single);
            sigma_k_eff = nan(size(w_safe));
            zero_w_mask = positive_i_mask & valid_w_mask & (w_safe == 0);
            sigma_k_eff(zero_w_mask) = 0;
            positive_w_mask = positive_i_mask & valid_w_mask & (w_safe > 0);
            if any(positive_w_mask(:))
                sigma_log = log(w_safe(positive_w_mask)) - ...
                    kdyn_d .* log(i_safe(positive_w_mask));
                finite_sigma_mask = isfinite(sigma_log) & ...
                    (sigma_log <= log(realmax('double')));
                sigma_vals = nan(size(sigma_log));
                sigma_vals(finite_sigma_mask) = exp(sigma_log(finite_sigma_mask));
                sigma_k_eff(positive_w_mask) = sigma_vals;
            end

            beta_k_eff = double(depletion_energy_j) * double(rho_nt_keldysh_norm_m3) .* sigma_k_eff;
            beta_k_eff(~isfinite(beta_k_eff)) = NaN;
        end

        function w_interp_fn = build_keldysh_w_interp_fn_from_loglinear_lut( ...
                i_lookup_wm2, w_lookup_sinv, i_lookup_min, i_lookup_max)
        %BUILD_KELDYSH_W_INTERP_FN_FROM_LOGLINEAR_LUT Build the runtime W(I) interpolant.
        % The runtime path uses a cheaper linear interpolation in
        % log(I)-log(W) space over strictly positive LUT segments. Queries
        % are clamped to the LUT edges before interpolation, and exact-zero
        % LUT bins stay exact zero outside those positive segments so the
        % installed W_ion(I) law does not silently lift zero-support bins
        % through log(realmin).

            i_lookup_vec = double(i_lookup_wm2(:));
            w_lookup_vec = real(double(w_lookup_sinv(:)));
            if isempty(i_lookup_vec) || (numel(i_lookup_vec) ~= numel(w_lookup_vec))
                error('CerUPP:Keldysh:InvalidRateLutShape', ...
                    'Keldysh W_ion(I) LUT inputs must be nonempty vectors of equal length.');
            end
            if any(~isfinite(i_lookup_vec)) || any(i_lookup_vec <= 0)
                error('CerUPP:Keldysh:InvalidIntensityLut', ...
                    ['Keldysh intensity LUT must contain only finite positive values ', ...
                     'before the runtime W_ion(I) interpolant is built.']);
            end
            if any(diff(i_lookup_vec) <= 0)
                error('CerUPP:Keldysh:NonMonotoneIntensityLut', ...
                    ['Keldysh intensity LUT must be strictly increasing before the ', ...
                     'runtime W_ion(I) interpolant is built.']);
            end
            if any(~isfinite(w_lookup_vec)) || any(w_lookup_vec < 0)
                error('CerUPP:Keldysh:InvalidRateLutValues', ...
                    ['Keldysh W_ion(I) LUT must contain only finite nonnegative values ', ...
                     'before the runtime interpolant is built.']);
            end
            % Preserve the sampled runtime law as built/loaded. The
            % install path may report a nonmonotone W_ion(I) LUT upstream,
            % but this interpolant does not repair or reject that shape.

            clamp_i = @(iq) min(max(double(iq), i_lookup_min), i_lookup_max);
            positive_mask = (w_lookup_vec > 0);
            if ~any(positive_mask)
                error('CerUPP:Keldysh:ZeroOnlyRateLut', ...
                    ['Keldysh W_ion(I) LUT contains no strictly positive sampled rates ' ...
                     'over [%.17g, %.17g] W/m^2. Refusing to install an enabled ' ...
                     'dynamic runtime law that would return W_ion(I)=0 across the ' ...
                     'whole clamped LUT window. Rebuild or reload the LUT so at ' ...
                     'least one sampled rate is strictly positive, or disable the ' ...
                     'dynamic Keldysh path.'], ...
                    i_lookup_min, i_lookup_max);
            end

            log_i_lookup = log(max(i_lookup_vec, realmin('double')));
            positive_seg_start = find(positive_mask & [true; ~positive_mask(1:end-1)]);
            positive_seg_end = find(positive_mask & [~positive_mask(2:end); true]);
            n_positive_seg = numel(positive_seg_start);
            positive_seg_i_min = zeros(n_positive_seg, 1);
            positive_seg_i_max = zeros(n_positive_seg, 1);
            positive_seg_interp = cell(n_positive_seg, 1);
            positive_seg_isolated = false(n_positive_seg, 1);
            positive_seg_i_exact = zeros(n_positive_seg, 1);
            positive_seg_w_exact = zeros(n_positive_seg, 1);
            for iseg = 1:n_positive_seg
                idx_seg = positive_seg_start(iseg):positive_seg_end(iseg);
                positive_seg_i_min(iseg) = i_lookup_vec(idx_seg(1));
                positive_seg_i_max(iseg) = i_lookup_vec(idx_seg(end));
                if numel(idx_seg) == 1
                    % Keep a one-bin positive onset as exact sampled support
                    % only. The runtime law does not invent a wider positive
                    % interval from one isolated LUT sample.
                    positive_seg_isolated(iseg) = true;
                    positive_seg_i_exact(iseg) = i_lookup_vec(idx_seg);
                    positive_seg_w_exact(iseg) = w_lookup_vec(idx_seg);
                else
                    positive_seg_interp{iseg} = griddedInterpolant( ...
                        log_i_lookup(idx_seg), log(w_lookup_vec(idx_seg)), ...
                        'linear', 'nearest');
                end
            end
            w_interp_fn = @zero_preserving_interp_local;

            function w_query = zero_preserving_interp_local(i_query)
                iq_clamped = clamp_i(i_query);
                w_query = zeros(size(iq_clamped));
                finite_query = isfinite(iq_clamped);
                w_query(~finite_query) = NaN;
                if ~any(finite_query(:))
                    return;
                end
                log_i_query = log(max(iq_clamped, realmin('double')));
                for iseg_local = 1:n_positive_seg
                    if positive_seg_isolated(iseg_local)
                        in_seg = finite_query & ...
                            (iq_clamped == positive_seg_i_exact(iseg_local));
                    else
                        in_seg = finite_query & ...
                            (iq_clamped >= positive_seg_i_min(iseg_local)) & ...
                            (iq_clamped <= positive_seg_i_max(iseg_local));
                    end
                    if ~any(in_seg(:))
                        continue;
                    end
                    if positive_seg_isolated(iseg_local)
                        w_query(in_seg) = positive_seg_w_exact(iseg_local);
                    else
                        w_query(in_seg) = exp( ...
                            positive_seg_interp{iseg_local}(log_i_query(in_seg)));
                    end
                end
            end
        end

        function y = plasma_keldysh_p1evl_vec_local(x, coef)
        % Evaluate x plus a polynomial tail with Horner's rule.

            y = x + coef(1);
            for kk = 2:numel(coef)
                y = y .* x + coef(kk);
            end
        end

        function [an, ad, bn, bd, cn, cd] = plasma_keldysh_dawson_coeffs_local()
        % Fixed rational-fit coefficients for dawson_real(...).
        % These are generic Dawson-function approximation coefficients for
        % the three-region rational helper used by dawson_real(...),
        % following Stephen L. Moshier's Cephes Mathematical Library
        % (https://www.netlib.org/cephes/). They are numerical fit tables,
        % not YAG or Keldysh material parameters, so memoize them here for
        % repeated LUT builds.

            persistent an_p ad_p bn_p bd_p cn_p cd_p
            if isempty(an_p)
                an_p = [ ...
                    1.13681498971755972054e-11, ...
                    8.49262267667473811108e-10, ...
                    1.94434204175553054283e-8, ...
                    9.53151741254484363489e-7, ...
                    3.07828309874913200438e-6, ...
                    3.52513368520288738649e-4, ...
                   -8.50149846724410912031e-4, ...
                    4.22618223005546594270e-2, ...
                   -9.17480371773452345351e-2, ...
                    9.99999999999999994612e-1];
                ad_p = [ ...
                    2.40372073066762605484e-11, ...
                    1.48864681368493396752e-9, ...
                    5.21265281010541664570e-8, ...
                    1.27258478273186970203e-6, ...
                    2.32490249820789513991e-5, ...
                    3.25524741826057911661e-4, ...
                    3.48805814657162590916e-3, ...
                    2.79448531198828973716e-2, ...
                    1.58874241960120565368e-1, ...
                    5.74918629489320327824e-1, ...
                    1.00000000000000000539e0];
                bn_p = [ ...
                    5.08955156417900903354e-1, ...
                   -2.44754418142697847934e-1, ...
                    9.41512335303534411857e-2, ...
                   -2.18711255142039025206e-2, ...
                    3.66207612329569181322e-3, ...
                   -4.23209114460388756528e-4, ...
                    3.59641304793896631888e-5, ...
                   -2.14640351719968974225e-6, ...
                    9.10010780076391431042e-8, ...
                   -2.40274520828250956942e-9, ...
                    3.59233385440928410398e-11];
                bd_p = [ ...
                   -6.31839869873368190192e-1, ...
                    2.36706788228248691528e-1, ...
                   -5.31806367003223277662e-2, ...
                    8.48041718586295374409e-3, ...
                   -9.47996768486665330168e-4, ...
                    7.81025592944552338085e-5, ...
                   -4.55875153252442634831e-6, ...
                    1.89100358111421846170e-7, ...
                   -4.91324691331920606875e-9, ...
                    7.18466403235734541950e-11];
                cn_p = [ ...
                   -5.90592860534773254987e-1, ...
                    6.29235242724368800674e-1, ...
                   -1.72858975380388136411e-1, ...
                    1.64837047825189632310e-2, ...
                   -4.86827613020462700845e-4];
                cd_p = [ ...
                   -2.69820057197544900361e0, ...
                    1.73270799045947845857e0, ...
                   -3.93708582281939493482e-1, ...
                    3.44278924041233391079e-2, ...
                   -9.73655226040941223894e-4];
            end
            an = an_p;
            ad = ad_p;
            bn = bn_p;
            bd = bd_p;
            cn = cn_p;
            cd = cd_p;
        end

    end

end
