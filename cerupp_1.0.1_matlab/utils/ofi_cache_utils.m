classdef ofi_cache_utils
%OFI_CACHE_UTILS Shared Keldysh runtime-context helpers for driver and propagator.
% Purpose:
% - Build the OFI/Keldysh runtime context used by setup, propagation, and
%   OFI-based NLA accounting.
% - Manage the optional on-disk Keldysh lookup files used by setup for
%   cache reuse and fresh rebuilds.
% Called mainly from plasma_setup_support.m and realspace_plasma_propagator.m.

        methods (Static)
        function ctx = build_keldysh_context(plasma_runtime_cfg, k_power_all, sigma_k_all)
        % Canonical Keldysh context builder shared by driver and propagator.
        % Contract:
        % - Disabled return: if plasma_runtime_cfg.keldysh_cfg is missing,
        %   empty, non-struct, or enabled=false, returns a disabled ctx
        %   with enabled=false and the standard field set.
        % - Enabled success: returns enabled=true plus the validated lookup
        %   direct W_ion(I) handle, active K/sigma vectors, lookup bounds,
        %   diagnostic-policy fields, and K_eff_single when that scalar is
        %   present for sigma/beta reporting.
        % - Enabled invalid: hard-errors with ofi_cache_utils-owned IDs when
        %   required fields are missing, malformed, or internally ambiguous.

            if ~isstruct(plasma_runtime_cfg) || ~isfield(plasma_runtime_cfg, 'keldysh_cfg') || ...
                    isempty(plasma_runtime_cfg.keldysh_cfg) || ~isstruct(plasma_runtime_cfg.keldysh_cfg)
                ctx = ofi_cache_utils_disabled_keldysh_context_local();
                return;
            end

            kcfg = plasma_runtime_cfg.keldysh_cfg;
            if ~(isfield(kcfg, 'enabled') && logical(kcfg.enabled))
                ctx = ofi_cache_utils_disabled_keldysh_context_local();
                return;
            end
            ctx = ofi_cache_utils_disabled_keldysh_context_local();
            ctx.enabled = true;

            err = ofi_cache_utils.keldysh_error_contract();

            has_w_ion_interp_scalar = isfield(kcfg, 'W_ion_interp_fn') && isa(kcfg.W_ion_interp_fn, 'function_handle');
            has_sigma_interp_scalar = isfield(kcfg, 'sigmaK_interp_fn') && isa(kcfg.sigmaK_interp_fn, 'function_handle');
            if has_sigma_interp_scalar
                error('ofi_cache_utils:UnsupportedSigmaInterpRuntime', ...
                    ['Dynamic Keldysh runtime uses W_ion_interp_fn directly. ', ...
                     'Remove keldysh_cfg.sigmaK_interp_fn and derive sigma/beta ', ...
                     'from W(I) in the diagnostic path instead.']);
            end
            if ~has_w_ion_interp_scalar
                error(err.missing_interp_id, err.missing_interp_msg);
            end
            if isfield(kcfg, 'K_eff_single')
                if ~(isscalar(kcfg.K_eff_single) && isnumeric(kcfg.K_eff_single) && ...
                        isreal(kcfg.K_eff_single) && isfinite(kcfg.K_eff_single) && ...
                        (kcfg.K_eff_single > 0))
                    error(err.invalid_k_id, err.invalid_k_msg, mat2str(kcfg.K_eff_single));
                end
                ctx.K_eff_single = double(kcfg.K_eff_single);
                if ~(isfinite(ctx.K_eff_single) && (ctx.K_eff_single > 0))
                    error(err.invalid_k_id, err.invalid_k_msg, mat2str(ctx.K_eff_single));
                end
            end

            ctx.idx_dyn = 1:numel(k_power_all);
            if ~isempty(sigma_k_all)
                ctx.sigmaK_static = max(double(sigma_k_all(1)), 0);
            else
                ctx.sigmaK_static = 0;
            end
            ctx.K_vec = double(k_power_all(:)).';
            ctx.sigmaK_vec = max(double(sigma_k_all(:)).', 0);

            ctx.policy = plasma_keldysh_setup.resolve_policy(kcfg);
            ctx.keff_bookkeeping_mode = ctx.policy.keff_bookkeeping_mode;
            ctx.W_ion_interp_fn = kcfg.W_ion_interp_fn;

            ctx.I_min = ofi_cache_utils.resolve_optional_keldysh_bound( ...
                kcfg, 'I_lookup_min', ctx.I_min, false, err);
            ctx.I_max = ofi_cache_utils.resolve_optional_keldysh_bound( ...
                kcfg, 'I_lookup_max', ctx.I_max, false, err);
            ctx.keldysh_zero_rate_below_wm2 = ofi_cache_utils.resolve_optional_keldysh_bound( ...
                kcfg, 'keldysh_zero_rate_below_wm2', ctx.I_min, true, err);
            if isfield(kcfg, 'W_lookup_sinv') && ~isempty(kcfg.W_lookup_sinv)
                w_lookup = double(kcfg.W_lookup_sinv(:));
                ctx.W_min_clamp_value = max(real(w_lookup(1)), 0);
                ctx.W_max_clamp_value = max(real(w_lookup(end)), 0);
            end
            if isfield(kcfg, 'omega_fund') && isfinite(kcfg.omega_fund) && (kcfg.omega_fund > 0)
                ctx.omega_fund = double(kcfg.omega_fund);
            end
            if isfield(kcfg, 'rho_nt_keldysh_norm_m3') && ...
                    isfinite(kcfg.rho_nt_keldysh_norm_m3) && (kcfg.rho_nt_keldysh_norm_m3 > 0)
                ctx.rho_nt_keldysh_norm_m3 = double(kcfg.rho_nt_keldysh_norm_m3);
            end
            if isfinite(ctx.I_min) && isfinite(ctx.I_max) && (ctx.I_max < ctx.I_min)
                error(err.invalid_bounds_id, err.invalid_bounds_msg, 'I_lookup', ctx.I_min, ctx.I_max);
            end
        end

    end
    methods (Static, Access = private)
        function err = keldysh_error_contract()
            root = 'ofi_cache_utils';
            err = struct( ...
                'invalid_k_id', [root ':KeldyshInvalidK'], ...
                'invalid_k_msg', 'Resolved K_eff_single is invalid for ofi_cache_utils: %s.', ...
                'missing_interp_id', [root ':KeldyshMissingInterp'], ...
                'missing_interp_msg', 'keldysh_cfg.enabled=true requires W_ion_interp_fn.', ...
                'invalid_bound_field_id', [root ':InvalidKeldyshLookupBoundField'], ...
                'invalid_bound_field_msg', ['keldysh_cfg.%s must be a finite real scalar %s; ' ...
                                            'got size %s of class %s.'], ...
                'invalid_bounds_id', [root ':InvalidKeldyshLookupBounds'], ...
                'invalid_bounds_msg', ['keldysh_cfg lookup bounds are invalid for ofi_cache_utils: ' ...
                                       '%s_min=%.6e exceeds %s_max=%.6e.']);
        end

        function val = resolve_optional_keldysh_bound(kcfg, field_name, default_val, allow_zero, varargin)
            if isempty(varargin)
                error('ofi_cache_utils:MissingBoundErrorContract', ...
                    'resolve_optional_keldysh_bound requires an error-contract struct.');
            end
            err = varargin{end};
            val = default_val;
            if ~isfield(kcfg, field_name) || isempty(kcfg.(field_name))
                return;
            end
            raw = kcfg.(field_name);
            if allow_zero
                is_valid = isscalar(raw) && isnumeric(raw) && isreal(raw) && isfinite(raw) && (double(raw) >= 0);
                lower_text = '>= 0';
            else
                is_valid = isscalar(raw) && isnumeric(raw) && isreal(raw) && isfinite(raw) && (double(raw) > 0);
                lower_text = '> 0';
            end
            if ~is_valid
                error(err.invalid_bound_field_id, err.invalid_bound_field_msg, ...
                    field_name, lower_text, mat2str(size(raw)), class(raw));
            end
            val = double(raw);
        end
    end

    methods (Static, Hidden)
        function lut_csv_path = resolve_keldysh_lookup_csv_path( ...
                run_output_root, keldysh_lookup_csv_name, cache_key)
        % Resolve the deterministic Keldysh LUT cache path under the shared cache root.

            if nargin < 3
                cache_key = [];
            end
            cache_dir = ofi_cache_utils_resolve_keldysh_cache_dir_local(run_output_root);
            name = strtrim(char(keldysh_lookup_csv_name));
            if isempty(name)
                error('ofi_cache_utils:InvalidKeldyshLookupCsvName', ...
                    'keldysh_lookup_csv_name must be nonempty.');
            end
            [~, stem, ext] = fileparts(name);
            if isempty(stem)
                error('ofi_cache_utils:InvalidKeldyshLookupCsvName', ...
                    'keldysh_lookup_csv_name must include a valid file stem.');
            end
            if isempty(ext)
                ext = '.csv';
            end
            if isempty(cache_key)
                cache_name = [stem ext];
            else
                cache_key_tag = ofi_cache_utils_build_keldysh_lookup_cache_key_local(cache_key);
                cache_name = sprintf('%s_%s%s', stem, cache_key_tag, ext);
            end
            lut_csv_path = fullfile(cache_dir, cache_name);
        end

        function cache_dir = ensure_keldysh_cache_dir(run_output_root)
        % Create the shared Keldysh cache directory only when a write is about to occur.

            cache_dir = ofi_cache_utils_resolve_keldysh_cache_dir_local(run_output_root);
            if exist(cache_dir, 'dir') == 7
                return;
            end
            [ok, msg, msgid] = mkdir(cache_dir);
            if ok || (exist(cache_dir, 'dir') == 7)
                return;
            end
            if isempty(msgid)
                msgid = 'mkdir';
            end
            if isempty(msg)
                msg = 'directory creation failed';
            end
            error('ofi_cache_utils:KeldyshCacheDirCreateFailed', ...
                'Could not create Keldysh cache directory "%s" (%s: %s).', ...
                cache_dir, msgid, msg);
        end

        function [k_power_all, sigma_k_all] = normalize_mpi_vectors(k_power_vec, sigma_k_vec)
            k_power_all = double(k_power_vec(:)).';
            sigma_k_all = double(sigma_k_vec(:)).';
            if numel(k_power_all) ~= numel(sigma_k_all)
                error('ofi_cache_utils:MpiVectorSizeMismatch', ...
                    'k_power_vec and sigma_k_vec must have equal length.');
            end
            if any(~isfinite(k_power_all)) || any(~isfinite(sigma_k_all))
                error('ofi_cache_utils:NonFiniteMPIParams', ...
                    'k_power_vec and sigma_k_vec must be finite.');
            end
            if any(k_power_all < 0)
                error('ofi_cache_utils:NegativeKPower', ...
                    'k_power_vec must be nonnegative.');
            end
            if any(sigma_k_all < 0)
                error('ofi_cache_utils:NegativeSigmaK', ...
                    'sigma_k_vec must be nonnegative.');
            end
        end

        function cache_meta = build_scalar_lookup_cache_meta( ...
                kcfg, n_coarse, n_roi, i_roi_min, i_roi_max, i_coarse_min, i_coarse_max)
        % Build the canonical scalar-lookup cache metadata struct once.

            cache_meta = ofi_cache_utils_build_scalar_lookup_cache_meta_local( ...
                kcfg, n_coarse, n_roi, i_roi_min, i_roi_max, i_coarse_min, i_coarse_max);
        end

        function lut_payload = build_scalar_lookup_payload( ...
                kcfg, cache_meta, i_lookup, w_lookup, gamma_lookup)
        % Build the MAT payload for a freshly computed scalar Keldysh lookup.

            lut_payload = ofi_cache_utils_build_scalar_lookup_payload_local( ...
                kcfg, cache_meta, i_lookup, w_lookup, gamma_lookup);
        end

        function [kcfg, lut_payload] = apply_scalar_lookup_payload( ...
                kcfg, lut_payload, lut_mat, lookup_provenance)
        % Install one scalar-lookup payload into the runtime cfg together
        % with additive provenance about how that LUT was obtained.

            if nargin < 4
                lookup_provenance = struct();
            end
            [kcfg, lut_payload] = ofi_cache_utils_apply_scalar_lookup_payload_local( ...
                kcfg, lut_payload, lut_mat, lookup_provenance);
        end

        function [lut_payload, cache_loaded] = try_load_scalar_lookup_payload( ...
                lut_mat, expected_cache_meta, skip_metadata_check)
        % Try to reuse one existing MAT lookup cache before rebuilding it.

            [lut_payload, cache_loaded] = ofi_cache_utils_try_load_scalar_lookup_payload_local( ...
                lut_mat, expected_cache_meta, skip_metadata_check);
        end

        function [run_warn_state, artifact_state] = emit_keldysh_setup_artifacts( ...
                kcfg, lut_payload, lut_dir, lut_mat, run_warn_state, ...
                phase_tag_for_summary, run_output_root, plot_policy_local, ...
                n_coarse, n_roi, i_roi_min, i_roi_max, k_power_vec_2, sigma_k_vec)
        % Emit the optional MAT/log/plot side effects for one finished Keldysh LUT.
        % The physics-facing kcfg struct is already complete before this helper
        % runs, so failures here only affect saved files, warnings, or setup plots.

            [run_warn_state, artifact_state] = ofi_cache_utils_emit_keldysh_setup_artifacts_local( ...
                kcfg, lut_payload, lut_dir, lut_mat, run_warn_state, ...
                phase_tag_for_summary, run_output_root, plot_policy_local, ...
                n_coarse, n_roi, i_roi_min, i_roi_max, k_power_vec_2, sigma_k_vec);
        end

        function k_eff_single_bookkeeping = resolve_scalar_lookup_bookkeeping_order(kcfg, varargin)
        % Resolve the scalar accounting order used for derived sigma/beta surfaces.

            k_eff_single_bookkeeping = ofi_cache_utils_resolve_scalar_lookup_bookkeeping_order_local( ...
                kcfg, varargin{:});
        end
    end
end

function lut_payload = ofi_cache_utils_build_scalar_lookup_payload_local( ...
        kcfg, cache_meta, i_lookup, w_lookup, gamma_lookup)
% Build the MAT payload for a computed scalar Keldysh lookup.

    lut_payload = struct( ...
        'I_Wm2', double(i_lookup(:)), ...
        'Wkeldysh_sinv', double(w_lookup(:)), ...
        'gamma', double(gamma_lookup(:)));
    lut_payload = ofi_cache_utils_copy_scalar_lookup_cache_fields_local(lut_payload, cache_meta);
    lut_payload.K_eff_single_bookkeeping = ...
        double(ofi_cache_utils_resolve_scalar_lookup_bookkeeping_order_local(kcfg));
end

function [lut_payload, cache_loaded] = ofi_cache_utils_try_load_scalar_lookup_payload_local( ...
        lut_mat, expected_cache_meta, skip_metadata_check)
% Try to reuse one existing MAT lookup cache before rebuilding it.

    lut_payload = struct();
    cache_loaded = false;
    if nargin < 3 || isempty(skip_metadata_check)
        skip_metadata_check = false;
    end
    if isstring(lut_mat) && isscalar(lut_mat)
        lut_mat = char(lut_mat);
    end
    if ~ischar(lut_mat) || isempty(strtrim(lut_mat))
        error('ofi_cache_utils:InvalidLookupMatPath', ...
            'lut_mat must be a nonempty char path.');
    end
    if exist(lut_mat, 'file') ~= 2
        return;
    end
    try
        loaded_payload = load(lut_mat);
    catch
        return;
    end
    if ~ofi_cache_utils_scalar_lookup_payload_has_required_fields_local(loaded_payload)
        return;
    end
    if ~logical(skip_metadata_check) && ...
            ~ofi_cache_utils_scalar_lookup_cache_meta_matches_local(loaded_payload, expected_cache_meta)
        return;
    end
    lut_payload = loaded_payload;
    cache_loaded = true;
end

function field_names = ofi_cache_utils_scalar_lookup_cache_field_names_local()
% Canonical physics-only metadata inventory shared by cache keys and LUT payloads.

    field_names = { ...
        'scalar_lookup_mode', 'scalar_lookup_version', ...
        'rho_nt_m3', 'rho_nt_keldysh_norm_m3', 'n_fund', 'Eg_J', 'mred_kg', ...
        'omega_fund', 'lambda_m', ...
        'N_coarse', 'N_roi', 'I_roi_min', 'I_roi_max', ...
        'I_coarse_min', 'I_coarse_max', 'use_solid_state_keldysh_flag', ...
        'keldysh_use_interference_corrected_rate_flag', 'keldysh_rate_formula', ...
        'lookup_cache_key_tag'};
end

function cache_meta = ofi_cache_utils_build_scalar_lookup_cache_meta_local( ...
        kcfg, n_coarse, n_roi, i_roi_min, i_roi_max, i_coarse_min, i_coarse_max)
% Build the canonical scalar-lookup cache metadata struct once.

    corrected_rate_flag = logical(struct_utils.opt_struct_field( ...
        kcfg, 'keldysh_use_interference_corrected_rate_flag', false));
    if corrected_rate_flag
        default_rate_formula = 'interference_corrected_kane_channel_sum_pos_arccot_v2';
    else
        default_rate_formula = 'legacy_solid_state_q_series';
    end
    resolved_rate_formula = char(string(struct_utils.opt_struct_field( ...
        kcfg, 'keldysh_rate_formula', default_rate_formula)));
    cache_meta = struct( ...
        'scalar_lookup_mode', char(string(kcfg.scalar_lookup_mode)), ...
        'scalar_lookup_version', double(kcfg.scalar_lookup_version), ...
        'rho_nt_m3', double(kcfg.rho_nt_m3), ...
        'rho_nt_keldysh_norm_m3', double(kcfg.rho_nt_keldysh_norm_m3), ...
        'n_fund', double(kcfg.n_fund), ...
        'Eg_J', double(kcfg.Eg_J), ...
        'mred_kg', double(kcfg.mred_kg), ...
        'omega_fund', double(kcfg.omega_fund), ...
        'lambda_m', double(kcfg.lambda_m), ...
        'N_coarse', double(n_coarse), ...
        'N_roi', double(n_roi), ...
        'I_roi_min', double(i_roi_min), ...
        'I_roi_max', double(i_roi_max), ...
        'I_coarse_min', double(i_coarse_min), ...
        'I_coarse_max', double(i_coarse_max), ...
        'use_solid_state_keldysh_flag', logical(kcfg.use_solid_state_keldysh_flag), ...
        'keldysh_use_interference_corrected_rate_flag', corrected_rate_flag, ...
        'keldysh_rate_formula', resolved_rate_formula);
    cache_meta.lookup_cache_key_tag = ...
        ofi_cache_utils_build_keldysh_lookup_cache_key_local(cache_meta);
end

function out_struct = ofi_cache_utils_copy_scalar_lookup_cache_fields_local(out_struct, cache_meta)
% Copy the canonical scalar-lookup metadata inventory onto another struct.

    field_names = ofi_cache_utils_scalar_lookup_cache_field_names_local();
    for ii = 1:numel(field_names)
        field_name = field_names{ii};
        out_struct.(field_name) = cache_meta.(field_name);
    end
end

function tf = ofi_cache_utils_scalar_lookup_payload_has_required_fields_local(lut_payload)
% Check that one loaded MAT struct has the lookup arrays needed for reuse.

    tf = isstruct(lut_payload) && ...
        isfield(lut_payload, 'I_Wm2') && ...
        isfield(lut_payload, 'Wkeldysh_sinv') && ...
        isfield(lut_payload, 'gamma');
end

function tf = ofi_cache_utils_scalar_lookup_cache_meta_matches_local(lut_payload, expected_cache_meta)
% Compare one loaded MAT payload against the canonical cache metadata set.

    tf = isstruct(lut_payload) && isstruct(expected_cache_meta);
    if ~tf
        return;
    end
    field_names = ofi_cache_utils_scalar_lookup_cache_field_names_local();
    for ii = 1:numel(field_names)
        field_name = field_names{ii};
        if ~isfield(lut_payload, field_name) || ~isfield(expected_cache_meta, field_name)
            tf = false;
            return;
        end
        cached_value = lut_payload.(field_name);
        expected_value = expected_cache_meta.(field_name);
        if ischar(expected_value) || (isstring(expected_value) && isscalar(expected_value))
            if ~strcmp(char(string(cached_value)), char(string(expected_value)))
                tf = false;
                return;
            end
        elseif islogical(expected_value)
            if ~(isscalar(cached_value) && (logical(cached_value) == logical(expected_value)))
                tf = false;
                return;
            end
        else
            if ~isequaln(double(cached_value), double(expected_value))
                tf = false;
                return;
            end
        end
    end
end

function [kcfg, lut_payload] = ofi_cache_utils_apply_scalar_lookup_payload_local( ...
        kcfg, lut_payload, lut_mat, lookup_provenance)
% Install a computed scalar-lookup payload into the runtime cfg.
% W(I) and gamma define the fresh runtime interpolation surface; sigma/beta
% accounting surfaces are regenerated from the current accounting order.

    if nargin < 4 || isempty(lookup_provenance)
        lookup_provenance = struct();
    elseif ~(isstruct(lookup_provenance) && isscalar(lookup_provenance))
        error('ofi_cache_utils:InvalidLookupProvenance', ...
            'lookup_provenance must be a scalar struct or [].');
    end

    i_lookup = double(lut_payload.I_Wm2(:));
    w_lookup = double(lut_payload.Wkeldysh_sinv(:));
    gamma_lookup = double(lut_payload.gamma(:));
    if any(diff(i_lookup) <= 0)
        error('plasma_keldysh_setup:InvalidKeldyshLookupGrid', ...
            ['Scalar lookup payload must preserve a strictly increasing unique I_Wm2 grid. ', ...
             'Refusing silent sort/deduplicate repair.']);
    end
    if numel(i_lookup) < 2
        error('plasma_keldysh_setup:KeldyshLookupInsufficientPoints', ...
            'Keldysh LUT payload must contain at least two distinct intensity points.');
    end
    if any(w_lookup < 0)
        bad_idx = find(w_lookup < 0, 1, 'first');
        error('plasma_keldysh_setup:InvalidNegativeKeldyshRate', ...
            ['Scalar lookup payload contains negative Wkeldysh_sinv at index %d. ', ...
             'Refusing silent flooring through the log-interpolant path.'], ...
            bad_idx);
    end
    % Preserve the computed/loaded runtime law exactly here. The runtime
    % interpolant builder below may still reject invalid support shapes, but
    % it does not repair sampled monotone dips before propagation starts.
    monotonicity_info = ofi_cache_utils_measure_keldysh_monotonicity_local( ...
        i_lookup, w_lookup, gamma_lookup, lut_payload);
    i_lookup_min = min(i_lookup);
    i_lookup_max = max(i_lookup);
    w_ion_interp_fn = plasma_keldysh_setup.build_keldysh_w_interp_fn_from_loglinear_lut( ...
        i_lookup, w_lookup, i_lookup_min, i_lookup_max);
    ui_j = double(struct_utils.opt_struct_field( ...
        kcfg, 'keldysh_matched_depletion_J', struct_utils.opt_struct_field(kcfg, 'Ui_J', NaN)));
    rho_nt_norm_eval = double(struct_utils.opt_struct_field(kcfg, 'rho_nt_keldysh_norm_m3', NaN));
    if ~(isscalar(ui_j) && isfinite(ui_j) && (ui_j > 0) && ...
            isscalar(rho_nt_norm_eval) && isfinite(rho_nt_norm_eval) && (rho_nt_norm_eval > 0))
        error('plasma_keldysh_setup:InvalidKeldyshLookupPayloadContext', ...
            ['Scalar lookup payload requires a finite positive matched-depletion bookkeeping energy ', ...
             '(keldysh_matched_depletion_J or Ui_J) and rho_nt_keldysh_norm_m3 in kcfg.']);
    end
    k_eff_single_bookkeeping = ofi_cache_utils_resolve_scalar_lookup_bookkeeping_order_local(kcfg, lut_payload);
    [sigma_k_lookup, beta_k_lookup] = plasma_keldysh_setup.compute_keldysh_sigma_beta_from_w( ...
        w_lookup, i_lookup, k_eff_single_bookkeeping, ui_j, ...
        rho_nt_norm_eval);

    kcfg.enabled = true;
    kcfg.W_ion_interp_fn = w_ion_interp_fn;
    kcfg.I_lookup_min = i_lookup_min;
    kcfg.I_lookup_max = i_lookup_max;
    kcfg.I_lookup_Wm2 = i_lookup;
    kcfg.W_lookup_sinv = w_lookup;
    kcfg.sigmaK_lookup = sigma_k_lookup;
    kcfg.betaK_lookup = beta_k_lookup;
    kcfg.gamma_lookup = gamma_lookup;
    kcfg.K_eff_single = double(k_eff_single_bookkeeping);
    kcfg.K_eff_single_bookkeeping = double(k_eff_single_bookkeeping);
    kcfg.lookup_cache_identity = 'runtime_rebuilt_standard_gamma';
    kcfg.lookup_mat = lut_mat;
    kcfg.lookup_source_mode = char(string(struct_utils.opt_struct_field( ...
        lookup_provenance, 'source_mode', 'fresh_rebuild')));
    kcfg.lookup_artifact_path = char(string(lut_mat));
    kcfg.lookup_cache_key_tag = char(string(struct_utils.opt_struct_field( ...
        lut_payload, 'lookup_cache_key_tag', '')));
    kcfg.lookup_reused_without_metadata_match = logical(struct_utils.opt_struct_field( ...
        lookup_provenance, 'reused_without_metadata_match', false));
    kcfg.lookup_nonmonotone_detected = logical(monotonicity_info.detected);
    kcfg.lookup_nonmonotone_large = logical(monotonicity_info.large_nonmonotone);
    kcfg.lookup_nonmonotone_count = double(monotonicity_info.count);
    kcfg.lookup_nonmonotone_max_rel = double(monotonicity_info.max_rel);
    kcfg.lookup_nonmonotone_review_tol_rel = double(monotonicity_info.review_tol_rel);
    kcfg.lookup_nonmonotone_first_idx = double(monotonicity_info.first_idx);
    kcfg.lookup_nonmonotone_first_i_lo = double(monotonicity_info.first_i_lo);
    kcfg.lookup_nonmonotone_first_i_hi = double(monotonicity_info.first_i_hi);
    kcfg.lookup_nonmonotone_first_w_lo = double(monotonicity_info.first_w_lo);
    kcfg.lookup_nonmonotone_first_w_hi = double(monotonicity_info.first_w_hi);
    kcfg.lookup_nonmonotone_max_idx = double(monotonicity_info.max_idx);
    kcfg.lookup_nonmonotone_max_i_lo = double(monotonicity_info.max_i_lo);
    kcfg.lookup_nonmonotone_max_i_hi = double(monotonicity_info.max_i_hi);
    kcfg.lookup_nonmonotone_max_w_lo = double(monotonicity_info.max_w_lo);
    kcfg.lookup_nonmonotone_max_w_hi = double(monotonicity_info.max_w_hi);
    kcfg.lookup_nonmonotone_max_nu_int_lo = double(monotonicity_info.max_nu_int_lo);
    kcfg.lookup_nonmonotone_max_nu_int_hi = double(monotonicity_info.max_nu_int_hi);
    kcfg.lookup_nonmonotone_max_nu_jump_detected = ...
        logical(monotonicity_info.max_nu_jump_detected);
    kcfg.lookup_monotonicity_repaired = false;
    kcfg.lookup_monotonicity_large_repair = false;
    kcfg.lookup_monotonicity_repair_count = 0;
    kcfg.lookup_monotonicity_repair_max_rel = 0;
    kcfg.lookup_monotonicity_repair_small_tol_rel = double(monotonicity_info.review_tol_rel);
    kcfg.lookup_monotonicity_repair_first_idx = NaN;
    kcfg.lookup_monotonicity_repair_first_i_lo = NaN;
    kcfg.lookup_monotonicity_repair_first_i_hi = NaN;
    kcfg.lookup_monotonicity_repair_first_w_lo = NaN;
    kcfg.lookup_monotonicity_repair_first_w_hi = NaN;
end

function monotonicity_info = ofi_cache_utils_measure_keldysh_monotonicity_local( ...
        i_lookup, w_lookup, gamma_lookup, lut_payload)
% Measure local downward steps in the installed Keldysh W_ion(I) LUT
% without repairing or rejecting the sampled runtime law.

    if nargin < 3
        gamma_lookup = [];
    end
    if nargin < 4
        lut_payload = struct();
    end
    i_lookup = double(i_lookup(:));
    w_lookup = double(w_lookup(:));
    monotonicity_info = struct( ...
        'detected', false, ...
        'large_nonmonotone', false, ...
        'count', 0, ...
        'max_rel', 0.0, ...
        'review_tol_rel', 5e-3, ...
        'first_idx', NaN, ...
        'first_i_lo', NaN, ...
        'first_i_hi', NaN, ...
        'first_w_lo', NaN, ...
        'first_w_hi', NaN, ...
        'max_idx', NaN, ...
        'max_i_lo', NaN, ...
        'max_i_hi', NaN, ...
        'max_w_lo', NaN, ...
        'max_w_hi', NaN, ...
        'max_nu_int_lo', NaN, ...
        'max_nu_int_hi', NaN, ...
        'max_nu_jump_detected', false);
    if numel(w_lookup) <= 1
        return;
    end

    w_prev = w_lookup(1:end-1);
    w_next = w_lookup(2:end);
    downward_abs = max(w_prev - w_next, 0.0);
    downward_mask = downward_abs > 0;
    if ~any(downward_mask)
        return;
    end

    pair_scale = max(max(w_prev, w_next), realmin('double'));
    downward_rel = downward_abs ./ pair_scale;
    [max_rel, max_idx] = max(downward_rel);
    first_idx = find(downward_mask, 1, 'first');
    monotonicity_info.detected = true;
    monotonicity_info.large_nonmonotone = ...
        max_rel > monotonicity_info.review_tol_rel;
    monotonicity_info.count = nnz(downward_mask);
    monotonicity_info.max_rel = max_rel;
    monotonicity_info.first_idx = first_idx;
    monotonicity_info.first_i_lo = i_lookup(first_idx);
    monotonicity_info.first_i_hi = i_lookup(first_idx + 1);
    monotonicity_info.first_w_lo = w_lookup(first_idx);
    monotonicity_info.first_w_hi = w_lookup(first_idx + 1);
    monotonicity_info.max_idx = max_idx;
    monotonicity_info.max_i_lo = i_lookup(max_idx);
    monotonicity_info.max_i_hi = i_lookup(max_idx + 1);
    monotonicity_info.max_w_lo = w_lookup(max_idx);
    monotonicity_info.max_w_hi = w_lookup(max_idx + 1);
    [nu_lo, nu_hi, nu_jump_detected] = ...
        ofi_cache_utils_measure_nonmonotone_threshold_jump_local( ...
            max_idx, gamma_lookup, lut_payload);
    monotonicity_info.max_nu_int_lo = nu_lo;
    monotonicity_info.max_nu_int_hi = nu_hi;
    monotonicity_info.max_nu_jump_detected = nu_jump_detected;
end

function [run_warn_state, artifact_state] = ofi_cache_utils_emit_keldysh_setup_artifacts_local( ...
        kcfg, lut_payload, lut_dir, lut_mat, run_warn_state, ...
        phase_tag_for_summary, run_output_root, plot_policy_local, ...
        n_coarse, n_roi, i_roi_min, i_roi_max, k_power_vec_2, sigma_k_vec)
% Emit the optional MAT/log/plot side effects for one finished Keldysh LUT.
% The runtime interpolants are already built before this helper runs, so
% failures here only affect saved files, warnings, or setup plots.

    if ~(isstruct(plot_policy_local) && isscalar(plot_policy_local))
        error('ofi_cache_utils:InvalidKeldyshPlotPolicy', ...
            'plot_policy_local must be an explicit scalar struct.');
    end

    artifact_state = struct('cache_dir_ready', true, 'plot_attempted', false);

    corrected_rate_flag = logical(struct_utils.opt_struct_field( ...
        kcfg, 'keldysh_use_interference_corrected_rate_flag', false));
    strongest_pair_text = sprintf( ...
        ['Strongest dip idx=%d->%d at I=[%.3e, %.3e] W/m^2 with ' ...
         'W=[%.3e, %.3e] 1/s.'], ...
        kcfg.lookup_nonmonotone_max_idx, ...
        kcfg.lookup_nonmonotone_max_idx + 1, ...
        kcfg.lookup_nonmonotone_max_i_lo, ...
        kcfg.lookup_nonmonotone_max_i_hi, ...
        kcfg.lookup_nonmonotone_max_w_lo, ...
        kcfg.lookup_nonmonotone_max_w_hi);
    if isfield(kcfg, 'lookup_nonmonotone_first_idx') && ...
            isfield(kcfg, 'lookup_nonmonotone_max_idx') && ...
            (kcfg.lookup_nonmonotone_first_idx == kcfg.lookup_nonmonotone_max_idx)
        first_pair_text = 'That strongest dip is also the first downward pair.';
    else
        first_pair_text = sprintf( ...
            ['The first downward pair is idx=%d->%d at I=[%.3e, %.3e] W/m^2 ' ...
             'with W=[%.3e, %.3e] 1/s.'], ...
            kcfg.lookup_nonmonotone_first_idx, ...
            kcfg.lookup_nonmonotone_first_idx + 1, ...
            kcfg.lookup_nonmonotone_first_i_lo, ...
            kcfg.lookup_nonmonotone_first_i_hi, ...
            kcfg.lookup_nonmonotone_first_w_lo, ...
            kcfg.lookup_nonmonotone_first_w_hi);
    end
    if isfield(kcfg, 'lookup_nonmonotone_max_nu_int_lo') && ...
            isfield(kcfg, 'lookup_nonmonotone_max_nu_int_hi') && ...
            isfinite(kcfg.lookup_nonmonotone_max_nu_int_lo) && ...
            isfinite(kcfg.lookup_nonmonotone_max_nu_int_hi)
        if isfield(kcfg, 'lookup_nonmonotone_max_nu_jump_detected') && ...
                logical(kcfg.lookup_nonmonotone_max_nu_jump_detected)
            baseline_threshold_text = sprintf( ...
                ['The strongest dip coincides with a discrete threshold-order ' ...
                 'jump nu_int=%g->%g.'], ...
                kcfg.lookup_nonmonotone_max_nu_int_lo, ...
                kcfg.lookup_nonmonotone_max_nu_int_hi);
        else
            baseline_threshold_text = sprintf( ...
                ['The strongest dip does not coincide with a discrete threshold-order ' ...
                 'jump; nu_int stays at %g->%g across that pair.'], ...
                kcfg.lookup_nonmonotone_max_nu_int_lo, ...
                kcfg.lookup_nonmonotone_max_nu_int_hi);
        end
    else
        baseline_threshold_text = ...
            'Threshold-order context for the strongest dip is unavailable.';
    end
    if isfield(kcfg, 'lookup_nonmonotone_detected') && ...
            logical(kcfg.lookup_nonmonotone_detected)
        if corrected_rate_flag
            if isfield(kcfg, 'lookup_nonmonotone_large') && ...
                    logical(kcfg.lookup_nonmonotone_large)
                run_warn_state = ofi_cache_utils_emit_phase_warning_local( ...
                    run_warn_state, phase_tag_for_summary, ...
                    'keldysh_lookup_nonmonotone_corrected_review', ...
                    'CerUPP:Keldysh:LookupNonMonotoneCorrectedExpectedReview', ...
                    ['Keldysh W_ion(I) LUT is visibly nonmonotone while the interference-corrected ', ...
                     'channel-sum branch is enabled. Keeping the sampled runtime law as-is because ', ...
                     'that corrected branch can produce nonmonotone segments; review the curve if ', ...
                     'the dip looks unexpected. Strongest local dip=%.3g relative exceeds the ', ...
                     'review threshold %.3g. %s %s'], ...
                    kcfg.lookup_nonmonotone_max_rel, ...
                    kcfg.lookup_nonmonotone_review_tol_rel, ...
                    strongest_pair_text, first_pair_text);
            else
                run_warn_state = ofi_cache_utils_emit_phase_warning_local( ...
                    run_warn_state, phase_tag_for_summary, ...
                    'keldysh_lookup_nonmonotone_corrected', ...
                    'CerUPP:Keldysh:LookupNonMonotoneCorrectedExpected', ...
                    ['Keldysh W_ion(I) LUT has %d downward step(s) while the interference-corrected ', ...
                     'channel-sum branch is enabled. Keeping the sampled runtime law as-is; that ', ...
                     'shape can be expected in the corrected branch. Strongest local dip=%.3g ', ...
                     'relative. %s %s'], ...
                    kcfg.lookup_nonmonotone_count, ...
                    kcfg.lookup_nonmonotone_max_rel, ...
                    strongest_pair_text, first_pair_text);
            end
        else
            if isfield(kcfg, 'lookup_nonmonotone_large') && ...
                    logical(kcfg.lookup_nonmonotone_large)
                run_warn_state = ofi_cache_utils_emit_phase_warning_local( ...
                    run_warn_state, phase_tag_for_summary, ...
                    'keldysh_lookup_nonmonotone_unexpected_review', ...
                    'CerUPP:Keldysh:LookupNonMonotoneUnexpectedReview', ...
                    ['Keldysh W_ion(I) LUT is visibly nonmonotone even though the interference-corrected ', ...
                     'channel-sum branch is off. Keeping the sampled runtime law as-is. In the ', ...
                     'legacy baseline branch, downward segments can appear near discrete threshold-order ', ...
                     'transitions, so this is a review note rather than proof that the baseline rate law ', ...
                     'is physically wrong. Strongest local dip=%.3g relative exceeds the review ', ...
                     'threshold %.3g. %s %s %s'], ...
                    kcfg.lookup_nonmonotone_max_rel, ...
                    kcfg.lookup_nonmonotone_review_tol_rel, ...
                    strongest_pair_text, first_pair_text, ...
                    baseline_threshold_text);
            else
                run_warn_state = ofi_cache_utils_emit_phase_warning_local( ...
                    run_warn_state, phase_tag_for_summary, ...
                    'keldysh_lookup_nonmonotone_unexpected', ...
                    'CerUPP:Keldysh:LookupNonMonotoneUnexpected', ...
                    ['Keldysh W_ion(I) LUT has %d downward step(s) even though the interference-corrected ', ...
                     'channel-sum branch is off. Keeping the sampled runtime law as-is. In the ', ...
                     'legacy baseline branch, downward segments can appear near discrete threshold-order ', ...
                     'transitions, so this is a review note rather than proof that the baseline rate law ', ...
                     'is physically wrong. Strongest local dip=%.3g relative. %s %s %s'], ...
                    kcfg.lookup_nonmonotone_count, ...
                    kcfg.lookup_nonmonotone_max_rel, ...
                    strongest_pair_text, first_pair_text, ...
                    baseline_threshold_text);
            end
        end
    end

    try
        ofi_cache_utils.ensure_keldysh_cache_dir(run_output_root);
    catch me_2
        artifact_state.cache_dir_ready = false;
        run_warn_state = ofi_cache_utils_emit_phase_warning_local( ...
            run_warn_state, phase_tag_for_summary, 'keldysh_lookup_cache_dir_create_failed', ...
            'CerUPP:KeldyshLookupCacheDirCreateFailed', ...
            'Failed to create Keldysh lookup cache directory "%s": %s', ...
            lut_dir, me_2.message);
    end

    if artifact_state.cache_dir_ready
        try
            save(lut_mat, '-struct', 'lut_payload', '-v7.3');
        catch me_2
            run_warn_state = ofi_cache_utils_emit_phase_warning_local( ...
                run_warn_state, phase_tag_for_summary, 'keldysh_lookup_mat_write_failed', ...
                'CerUPP:KeldyshLookupMatWriteFailed', ...
                'Failed to write Keldysh lookup MAT output "%s": %s', ...
                lut_mat, me_2.message);
        end
    end

    [run_warn_state, ~] = run_warn_state_utils.emit_info_with_phase( ...
        run_warn_state, phase_tag_for_summary, 'keldysh_lut_grid_summary', ...
        'Keldysh LUT grid: N=%d (global=%d, ROI=%d), I=[%.3e, %.3e], ROI=[%.3e, %.3e]', ...
        numel(kcfg.I_lookup_Wm2), n_coarse, n_roi, ...
        min(kcfg.I_lookup_Wm2), max(kcfg.I_lookup_Wm2), i_roi_min, i_roi_max);

    keldysh_plot_outdir = char(string(struct_utils.opt_struct_field( ...
        plot_policy_local, 'outdir', '')));
    save_outputs_as_fig_local = logical(struct_utils.opt_struct_field( ...
        plot_policy_local, 'save_outputs_as_fig', false));
    save_outputs_as_png_local = logical(struct_utils.opt_struct_field( ...
        plot_policy_local, 'save_outputs_as_png', false));
    show_plots_flag_local = logical(struct_utils.opt_struct_field( ...
        plot_policy_local, 'visible', false));
    want_keldysh_diag_plot = logical(show_plots_flag_local) || ...
        logical(save_outputs_as_fig_local) || logical(save_outputs_as_png_local);
    if ~want_keldysh_diag_plot
        return;
    end

    artifact_state.plot_attempted = true;
    try
        if isempty(keldysh_plot_outdir) && ~isempty(run_output_root)
            keldysh_plot_outdir = fullfile(run_output_root, 'output_plots');
        end
        plot_policy_local.outdir = keldysh_plot_outdir;
        plot_policy_local.visible = show_plots_flag_local;
        plot_policy_local.save_outputs_as_fig = save_outputs_as_fig_local;
        plot_policy_local.save_outputs_as_png = save_outputs_as_png_local;
        run_warn_state = plot_support_utils.plot_keldysh_rate_diagnostic( ...
            kcfg.I_lookup_Wm2, kcfg.W_lookup_sinv, ...
            k_power_vec_2, sigma_k_vec, ...
            struct_utils.opt_struct_field(kcfg, 'K_eff_single_bookkeeping', NaN), ...
            kcfg.rho_nt_keldysh_norm_m3, kcfg.rho_nt_m3, ...
            plot_policy_local, run_warn_state, ...
            'phase_tag', phase_tag_for_summary);
    catch me_plot
        run_warn_state = ofi_cache_utils_emit_phase_warning_local( ...
            run_warn_state, phase_tag_for_summary, ...
            'keldysh_setup_plot_skipped', ...
            'CerUPP:KeldyshSetupPlotSkipped', ...
            'Skipping Keldysh setup diagnostic plot (dynamic W(I) remains enabled): %s', ...
            me_plot.message);
    end
end

function [nu_lo, nu_hi, nu_jump_detected] = ...
        ofi_cache_utils_measure_nonmonotone_threshold_jump_local( ...
        pair_idx, gamma_lookup, lut_payload)
% Recover the discrete threshold-order context for the strongest dip pair.

    nu_lo = NaN;
    nu_hi = NaN;
    nu_jump_detected = false;
    if ~(isscalar(pair_idx) && isfinite(pair_idx) && ...
            (pair_idx >= 1) && (floor(pair_idx) == pair_idx))
        return;
    end
    gamma_lookup = double(gamma_lookup(:));
    if numel(gamma_lookup) < (pair_idx + 1)
        return;
    end
    if ~(isstruct(lut_payload) && isscalar(lut_payload))
        return;
    end
    eg_j = double(struct_utils.opt_struct_field(lut_payload, 'Eg_J', NaN));
    omega = double(struct_utils.opt_struct_field(lut_payload, 'omega_fund', NaN));
    if ~(isscalar(eg_j) && isfinite(eg_j) && (eg_j > 0) && ...
            isscalar(omega) && isfinite(omega) && (omega > 0))
        return;
    end

    nu_pair = ofi_cache_utils_keldysh_nu_from_gamma_local( ...
        gamma_lookup(pair_idx:pair_idx + 1), eg_j, omega);
    if any(~isfinite(nu_pair(:)))
        return;
    end
    nu_lo = double(nu_pair(1));
    nu_hi = double(nu_pair(2));
    nu_jump_detected = (nu_lo ~= nu_hi);
end

function nu_int = ofi_cache_utils_keldysh_nu_from_gamma_local( ...
        gamma, eg_j, omega)
% Match the solid-state Keldysh threshold-order scan used by the LUT build.

    hbar = 1.054571817e-34;
    gamma = max(double(gamma(:)), 1e-12);
    gamma1 = gamma.^2 ./ (1 + gamma.^2);
    gamma2 = 1 ./ (1 + gamma.^2);
    gamma1 = min(max(gamma1, 0.0), 1.0 - eps);
    gamma2 = min(max(gamma2, 0.0), 1.0 - eps);
    [~, e2] = ellipke(gamma2);
    eg_tilde = (2 / pi) * eg_j ./ ...
        sqrt(max(gamma1, realmin('double'))) .* e2;
    nu_cont = max(eg_tilde ./ (hbar .* omega) + 1, 1);
    nu_tol = max(1024 * eps(max(abs(nu_cont), 1.0)), 1e-12);
    nu_int = max(floor(nu_cont + nu_tol), 1);
end

function k_eff_single_bookkeeping = ofi_cache_utils_resolve_scalar_lookup_bookkeeping_order_local(kcfg, varargin)
% Resolve the scalar accounting order used for derived sigma/beta surfaces.

    k_eff_single_bookkeeping = NaN;
    if nargin >= 1 && isstruct(kcfg)
        if isfield(kcfg, 'K_eff_single_bookkeeping') && ...
                isfinite(kcfg.K_eff_single_bookkeeping) && (kcfg.K_eff_single_bookkeeping > 0)
            k_eff_single_bookkeeping = double(kcfg.K_eff_single_bookkeeping);
        end
    end
    if ~isfinite(k_eff_single_bookkeeping) && (nargin >= 2) && isstruct(varargin{1})
        lut_payload = varargin{1};
        if isfield(lut_payload, 'K_eff_single_bookkeeping') && ...
                isfinite(lut_payload.K_eff_single_bookkeeping) && (lut_payload.K_eff_single_bookkeeping > 0)
            k_eff_single_bookkeeping = double(lut_payload.K_eff_single_bookkeeping);
        end
    end
    if ~(isfinite(k_eff_single_bookkeeping) && (k_eff_single_bookkeeping > 0))
        error('plasma_keldysh_setup:InvalidKeldyshBookkeepingOrder', ...
            'Scalar Keldysh accounting requires a finite positive K_eff_single value.');
    end
end

function run_warn_state = ofi_cache_utils_emit_phase_warning_local( ...
        run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin)
% Emit one setup-phase warning for the Keldysh lookup artifact path.

    if nargin < 2 || isempty(phase_tag)
        error('ofi_cache_utils:MissingPhaseTag', ...
            'phase_tag is required for Keldysh setup artifact warnings.');
    end
    run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
        run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin{:});
end

function cache_dir = ofi_cache_utils_resolve_keldysh_cache_dir_local(run_output_root)
% Purely resolve the shared base-cache directory for Keldysh LUT files.

    if isstring(run_output_root) && isscalar(run_output_root)
        run_output_root = char(run_output_root);
    end
    if ~ischar(run_output_root) || isempty(strtrim(run_output_root))
        error('ofi_cache_utils:InvalidRunOutputRoot', ...
            'run_output_root must be a nonempty char path.');
    end
    cache_root = fileparts(run_output_root);
    if isempty(cache_root)
        cache_root = run_output_root;
    end
    if isempty(cache_root)
        error('ofi_cache_utils:InvalidKeldyshCacheRoot', ...
            'Could not resolve cache root from run_output_root="%s".', run_output_root);
    end
    cache_dir = fullfile(cache_root, 'keldysh_lookup_cache');
end

function cache_key_tag = ofi_cache_utils_build_keldysh_lookup_cache_key_local(cache_key)
% Build a deterministic file-safe cache key for Keldysh LUT files.

    req = {'scalar_lookup_mode','scalar_lookup_version','rho_nt_m3','rho_nt_keldysh_norm_m3', ...
           'n_fund','Eg_J','mred_kg','N_coarse','N_roi','I_roi_min','I_roi_max', ...
           'I_coarse_min','I_coarse_max','use_solid_state_keldysh_flag', ...
           'keldysh_use_interference_corrected_rate_flag','keldysh_rate_formula'};
    if ~isstruct(cache_key)
        error('ofi_cache_utils:InvalidKeldyshCacheKey', ...
            'cache_key must be a struct.');
    end
    missing = req(~isfield(cache_key, req));
    if ~isempty(missing)
        error('ofi_cache_utils:InvalidKeldyshCacheKey', ...
            'Missing cache_key fields: %s', strjoin(missing, ', '));
    end
    scalar_lookup_version = round(double(cache_key.scalar_lookup_version));
    nc = round(double(cache_key.N_coarse));
    nr = round(double(cache_key.N_roi));
    omega_for_key = ofi_cache_utils_resolve_cache_key_carrier_omega_local(cache_key);
    scalar_lookup_mode = char(string(cache_key.scalar_lookup_mode));
    use_solid_state_keldysh_flag = logical(cache_key.use_solid_state_keldysh_flag);
    corrected_rate_flag = logical(cache_key.keldysh_use_interference_corrected_rate_flag);
    rate_formula = char(string(cache_key.keldysh_rate_formula));
    has_bookkeeping_k = isfield(cache_key, 'K_eff_single') && ...
        ~isempty(cache_key.K_eff_single) && isfinite(double(cache_key.K_eff_single)) && ...
        (double(cache_key.K_eff_single) > 0);
    if has_bookkeeping_k
        k_for_key = double(cache_key.K_eff_single);
    end

    tok_num = @(x) regexprep(sprintf('%.6e', double(x)), {'\+','-','\.'}, {'','m','p'});
    bounds_tag = sprintf('Ilo_%s_Ihi_%s_Irlo_%s_Irhi_%s_Nc_%d_Nr_%d', ...
        tok_num(cache_key.I_coarse_min), ...
        tok_num(cache_key.I_coarse_max), ...
        tok_num(cache_key.I_roi_min), ...
        tok_num(cache_key.I_roi_max), ...
        nc, nr);
    physics_hash_args = { ...
        scalar_lookup_version, ...
        double(cache_key.rho_nt_m3), ...
        double(cache_key.rho_nt_keldysh_norm_m3), ...
        double(cache_key.n_fund), ...
        double(cache_key.Eg_J), ...
        double(cache_key.mred_kg), ...
        omega_for_key, ...
        nc, nr, ...
        double(cache_key.I_roi_min), double(cache_key.I_roi_max), ...
        double(cache_key.I_coarse_min), double(cache_key.I_coarse_max)};

    if has_bookkeeping_k
        hash_src = sprintf([ ...
            'bookkeepingK|mode=%s|sv=%d|solid=%d|corr=%d|formula=%s|K=%.15g|' ...
            'rho=%.15g|rho_norm=%.15g|n=%.15g|Eg=%.15g|mred=%.15g|' ...
            'omega=%.15g|Nc=%d|Nr=%d|Iroi=[%.15g,%.15g]|Icoarse=[%.15g,%.15g]'], ...
            scalar_lookup_mode, scalar_lookup_version, ...
            use_solid_state_keldysh_flag, corrected_rate_flag, rate_formula, ...
            k_for_key, physics_hash_args{2:end});
    else
        hash_src = sprintf([ ...
            'physics|mode=%s|sv=%d|solid=%d|corr=%d|formula=%s|' ...
            'rho=%.15g|rho_norm=%.15g|n=%.15g|Eg=%.15g|mred=%.15g|' ...
            'omega=%.15g|Nc=%d|Nr=%d|Iroi=[%.15g,%.15g]|Icoarse=[%.15g,%.15g]'], ...
            scalar_lookup_mode, scalar_lookup_version, ...
            use_solid_state_keldysh_flag, corrected_rate_flag, rate_formula, ...
            physics_hash_args{2:end});
    end
    hash_tag = ofi_cache_utils_fnv1a32_hex_local(hash_src);
    cache_key_tag = sprintf('%s_h%s', bounds_tag, hash_tag);
end

function omega_fund = ofi_cache_utils_resolve_cache_key_carrier_omega_local(cache_key)
% Canonicalize the carrier degree of freedom onto omega_fund for cache keys.

    if isfield(cache_key, 'omega_fund')
        raw = cache_key.omega_fund;
        if isscalar(raw) && isnumeric(raw) && isreal(raw) && isfinite(raw) && (double(raw) > 0)
            omega_fund = double(raw);
            return;
        end
    end
    if isfield(cache_key, 'lambda_m')
        raw = cache_key.lambda_m;
        if isscalar(raw) && isnumeric(raw) && isreal(raw) && isfinite(raw) && (double(raw) > 0)
            omega_fund = 2 * pi * 299792458 / double(raw);
            return;
        end
    end
    error('ofi_cache_utils:InvalidKeldyshCacheKey', ...
        'cache_key must provide a finite positive omega_fund or lambda_m.');
end

function hex_txt = ofi_cache_utils_fnv1a32_hex_local(str_in)
% Compute lowercase 8-hex-digit FNV-1a hash for deterministic cache keys.

    bytes = uint8(char(str_in));
    h = uint32(hex2dec('811C9DC5'));
    prime = uint32(16777619);
    mod32 = uint64(2)^32;
    for ii = 1:numel(bytes)
        h = bitxor(h, uint32(bytes(ii)));
        h = uint32(mod(uint64(h) * uint64(prime), mod32));
    end
    hex_txt = lower(dec2hex(h, 8));
end

function ctx = ofi_cache_utils_disabled_keldysh_context_local()
% Return the canonical disabled Keldysh context shell.

    ctx = struct( ...
        'enabled', false, ...
        'idx_dyn', [], ...
        'K_eff_single', NaN, ...
        'K_vec', [], ...
        'sigmaK_vec', [], ...
        'W_ion_interp_fn', [], ...
        'I_min', NaN, ...
        'I_max', NaN, ...
        'keldysh_zero_rate_below_wm2', NaN, ...
        'W_min_clamp_value', 0, ...
        'W_max_clamp_value', 0, ...
        'omega_fund', NaN, ...
        'rho_nt_keldysh_norm_m3', NaN, ...
        'policy', struct(), ...
        'keff_bookkeeping_mode', 'unresolved', ...
        'sigmaK_static', 0);
end
