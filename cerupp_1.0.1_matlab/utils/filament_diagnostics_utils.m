classdef filament_diagnostics_utils
%FILAMENT_DIAGNOSTICS_UTILS Filament onset/notch/width analysis helpers.
% Purpose:
% - Own the filament-specific onset, notch, and width analysis routines.
% - Keep the shared masked-spectrum band reducers in band_diagnostics_utils
%   so this file stays focused on filament analysis policy.
% Called mainly from cerupp.m and cerupp_section6a_postprocess.m.

    methods (Static)
        function [det, run_warn_state] = detect_onset_trace( ...
                trace_vec, z_vec, method_name, threshold_basis_value, ...
                frac_threshold, label, varargin)
        % DETECT_ONSET_TRACE Stable public onset-detection entry point.
        % Supported method_name values are threshold_crossing,
        % first_decrease_after_threshold, and slope_to_peak.
        % threshold_basis_value / frac_threshold are used by the threshold
        % methods, while the optional trailing inputs are w and
        % run_warn_state. If exactly one optional trailing input is given
        % and it is a scalar struct, it is treated as run_warn_state with
        % w left empty. Returned det.onset_idx indexes the supplied
        % trace_vec / z_vec samples.

            if nargin < 3 || isempty(method_name)
                method_name = 'threshold_crossing';
            end
            if nargin < 4 || isempty(threshold_basis_value)
                threshold_basis_value = NaN;
            end
            if nargin < 5 || isempty(frac_threshold)
                frac_threshold = NaN;
            end
            if nargin < 6 || isempty(label)
                label = '';
            end

            w = [];
            run_warn_state = struct();
            if ~isempty(varargin)
                first_optional = varargin{1};
                if isstruct(first_optional) && isscalar(first_optional) && ...
                        numel(varargin) == 1
                    run_warn_state = first_optional;
                else
                    w = first_optional;
                    if numel(varargin) >= 2
                        run_warn_state = varargin{2};
                    end
                    if numel(varargin) > 2
                        error('CerUPP:OnsetDetect:TooManyOptionalInputs', ...
                            ['detect_onset_trace accepts at most two ', ...
                             'optional trailing inputs: w and ', ...
                             'run_warn_state.']);
                    end
                end
            end

            if isempty(run_warn_state)
                run_warn_state = struct();
            elseif ~(isstruct(run_warn_state) && isscalar(run_warn_state))
                error('CerUPP:OnsetDetect:InvalidWarnState', ...
                    'run_warn_state must be a scalar struct or []; got %s.', ...
                    class(run_warn_state));
            end

            method_key = lower(strtrim(char(string(method_name))));
            switch method_key
                case 'threshold_crossing'
                    det = filament_diagnostics_utils_detect_threshold_crossing_core_impl( ...
                        trace_vec, z_vec, threshold_basis_value, frac_threshold, label, ...
                        'threshold_crossing', false);
                case 'first_decrease_after_threshold'
                    det = filament_diagnostics_utils_first_decrease_after_threshold( ...
                        trace_vec, z_vec, threshold_basis_value, frac_threshold, label, w);
                case 'slope_to_peak'
                    [det, run_warn_state] = filament_diagnostics_utils_detect_slope_to_peak_impl( ...
                        z_vec, trace_vec, w, label, run_warn_state);
                otherwise
                    error('CerUPP:OnsetDetect:UnknownMethod', ...
                        ['Unknown onset-detection method "%s". Supported canonical methods: ', ...
                         'threshold_crossing, first_decrease_after_threshold, slope_to_peak.'], ...
                        method_name);
            end
        end

        function [det, run_warn_state] = detect_onset_from_priority_traces( ...
                store_max_rho, store_fluence_xy_visible, store_fpeak_vis, ...
                store_fluence_vis_onaxis, valid, ix_oa, iy_oa, z_vec, w, run_warn_state)
        % DETECT_ONSET_FROM_PRIORITY_TRACES Apply the driver onset-priority policy on a physical z grid.
        % Uses z_vec when available; if z_vec is empty, returns the
        % missing_z_vec status and leaves z_onset = NaN.
        % valid and det.onset_idx stay in the original stored-plane indexing,
        % not in a compressed finite-z subset.

            if nargin < 4 || isempty(store_fluence_vis_onaxis)
                store_fluence_vis_onaxis = [];
            end
            if nargin < 5 || isempty(valid)
                valid = [];
            end
            if nargin < 6 || isempty(ix_oa)
                ix_oa = [];
            end
            if nargin < 7 || isempty(iy_oa)
                iy_oa = [];
            end
            if nargin < 8 || isempty(z_vec)
                z_vec = [];
            end
            if nargin < 9
                w = [];
            end
            if nargin < 10 || isempty(run_warn_state)
                run_warn_state = struct();
            end

            valid = valid(:);
            det = struct( ...
                'success', false, ...
                'indicator_label', 'none', ...
                'onset_idx', NaN, ...
                'sample_onset_idx', NaN, ...
                'z_onset', NaN, ...
                'axis_kind', 'physical_z', ...
                'detector', filament_diagnostics_utils_build_onset_det_local( ...
                    'priority_trace', '', NaN, NaN, NaN, 'all_indicators_failed'), ...
                'indicator_specs', repmat(struct( ...
                    'label', '', 'enabled', false, 'trace', [], 'sample_idx', []), 4, 1), ...
                'status', filament_diagnostics_utils_make_status_local('all_indicators_failed'));
            if isempty(z_vec)
                det.indicator_specs = fil_diag_build_priority_onset_specs_impl( ...
                    store_max_rho, store_fluence_xy_visible, store_fpeak_vis, ...
                    store_fluence_vis_onaxis, valid, ix_oa, iy_oa);
                det.detector = filament_diagnostics_utils_build_onset_det_local( ...
                    'priority_trace', '', NaN, NaN, NaN, 'missing_z_vec');
                det.status = filament_diagnostics_utils_make_status_local('missing_z_vec');
                return;
            end

            z_vec = z_vec(:);
            if isempty(valid)
                valid = (1:numel(z_vec)).';
            end
            valid = fil_diag_filter_valid_indices_local(valid, numel(z_vec));
            det.indicator_specs = fil_diag_build_priority_onset_specs_impl( ...
                store_max_rho, store_fluence_xy_visible, store_fpeak_vis, ...
                store_fluence_vis_onaxis, valid, ix_oa, iy_oa);

            any_enabled = false;
            for onset_indicator_idx = 1:numel(det.indicator_specs)
                onset_spec = det.indicator_specs(onset_indicator_idx);
                if ~logical(onset_spec.enabled)
                    continue;
                end
                any_enabled = true;
                if isempty(onset_spec.sample_idx)
                    continue;
                end
                z_detect = z_vec(onset_spec.sample_idx);
                [onset_det, run_warn_state] = filament_diagnostics_utils.detect_onset_trace( ...
                    onset_spec.trace(:), z_detect, 'slope_to_peak', NaN, NaN, onset_spec.label, w, run_warn_state);
                if isfield(onset_det, 'onset_idx') && isfinite(onset_det.onset_idx)
                    onset_idx_local = double(onset_det.onset_idx);
                    if ~(onset_idx_local >= 1 && onset_idx_local <= numel(onset_spec.sample_idx))
                        continue;
                    end
                    onset_idx = onset_spec.sample_idx(onset_idx_local);
                    det.success = true;
                    det.indicator_label = onset_spec.label;
                    det.onset_idx = onset_idx;
                    det.sample_onset_idx = onset_idx_local;
                    if onset_idx_local >= 1 && onset_idx_local <= numel(z_detect)
                        det.z_onset = z_detect(onset_idx_local);
                    else
                        det.z_onset = NaN;
                    end
                    det.detector = onset_det;
                    det.status = filament_diagnostics_utils_make_status_local('ok');
                    return;
                end
            end

            if ~any_enabled
                det.status = filament_diagnostics_utils_make_status_local('no_enabled_indicators');
            end
        end

        function [onset_state, run_warn_state] = build_detected_onset_analysis_state( ...
                store_max_rho, store_fluence_xy_visible, store_fpeak_vis, ...
                store_fluence_vis_onaxis, store_z, ix_oa, iy_oa, run_warn_state)
        % BUILD_DETECTED_ONSET_ANALYSIS_STATE Resolve the shared onset-analysis state once.
        % Section 6 callers use this compact state instead of rebuilding the
        % valid-index, z-window, and onset-detector policy in parallel.

            if nargin < 4 || isempty(store_fluence_vis_onaxis)
                store_fluence_vis_onaxis = [];
            end
            if nargin < 5 || isempty(store_z)
                store_z = [];
            end
            if nargin < 6 || isempty(ix_oa)
                ix_oa = [];
            end
            if nargin < 7 || isempty(iy_oa)
                iy_oa = [];
            end
            if nargin < 8 || isempty(run_warn_state)
                run_warn_state = struct();
            end

            z_all = store_z(:);
            valid = find(isfinite(z_all) & (z_all >= 0));
            if isempty(valid)
                valid = (1:numel(z_all)).';
            end
            z_use = z_all(valid);
            onset_window_policy = filament_diagnostics_utils_onset_window_policy(z_use);
            onset_det = filament_diagnostics_utils_build_onset_det_local( ...
                'priority_trace', '', NaN, NaN, NaN, onset_window_policy.reason);
            if onset_window_policy.supported
                [onset_det, run_warn_state] = filament_diagnostics_utils.detect_onset_from_priority_traces( ...
                    store_max_rho, store_fluence_xy_visible, store_fpeak_vis, ...
                    store_fluence_vis_onaxis, valid, ix_oa, iy_oa, z_all, ...
                    onset_window_policy.window_samples, run_warn_state);
            end
            onset_state = struct( ...
                'valid', valid, ...
                'z_use', z_use, ...
                'window_rule_name', onset_window_policy.rule_name, ...
                'window_supported', onset_window_policy.supported, ...
                'window_status_code', onset_window_policy.reason, ...
                'window_target_span_m', onset_window_policy.target_span_m, ...
                'window_effective_span_m', onset_window_policy.effective_span_m, ...
                'window_median_dz_m', onset_window_policy.median_dz_m, ...
                'minimum_supported_median_dz_m', onset_window_policy.minimum_supported_median_dz_m, ...
                'window_samples', onset_window_policy.window_samples, ...
                'onset_det', onset_det);
        end

        function [num_fils, fil_ent_locations, fil_exit_locations, fil_lengths, run_warn_state] = get_num_notches(z_domain, profile_trace, cutoff, varargin)
        % GET_NUM_NOTCHES Detect contiguous above-threshold z intervals in a trace.
        % profile_trace may be a plain trace vector on z_domain or an
        % Nx2 / 2xN [z, trace] pair carrying its own trace grid.
        % Optional eps_z controls overlap matching when profile_trace
        % provides an independent z grid. Plain-vector traces must match
        % z_domain exactly in length; silent truncation is refused.

            num_fils = NaN;
            fil_ent_locations = [];
            fil_exit_locations = [];
            fil_lengths = [];
            run_warn_state = struct();

            if ~isempty(varargin) && isstruct(varargin{end})
                run_warn_state = varargin{end};
                varargin = varargin(1:end-1);
            end

            if nargin < 3 || isempty(z_domain) || isempty(profile_trace) || isempty(cutoff)
                run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                    run_warn_state, 'CerUPP:GetNumNotches:EmptyInput', ...
                    'Inputs missing/empty. Returning NaN notches.');
                return;
            end
            if ~isscalar(cutoff) || ~isfinite(cutoff)
                run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                    run_warn_state, 'CerUPP:GetNumNotches:BadCutoff', ...
                    'Cutoff must be a finite scalar. Returning NaN notches.');
                return;
            end

            z_base = z_domain(:);
            if isempty(z_base)
                run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                    run_warn_state, 'CerUPP:GetNumNotches:ZeroLengthZ', ...
                    'z_domain has zero usable length. Returning NaN notches.');
                return;
            end
            num_fils = 0;

            if isempty(varargin) || isempty(varargin{1})
                z_scale = max(abs(z_base(isfinite(z_base))));
                if isempty(z_scale), z_scale = 1; end
                eps_z = 1e-12 * max(1, z_scale);
            else
                eps_z = varargin{1};
                if ~isscalar(eps_z) || ~isfinite(eps_z) || eps_z < 0
                    error('get_num_notches:BadEps', ...
                        'eps_z must be a finite nonnegative scalar.');
                end
            end

            z_trace = [];
            if isvector(profile_trace)
                p_raw = profile_trace(:);
            elseif isnumeric(profile_trace) && size(profile_trace, 2) == 2
                z_trace = profile_trace(:,1);
                p_raw = profile_trace(:,2);
            elseif isnumeric(profile_trace) && size(profile_trace, 1) == 2
                z_trace = profile_trace(1,:).';
                p_raw = profile_trace(2,:).';
            else
                error('get_num_notches:BadProfileShape', ...
                    'profile_trace must be vector or Nx2/2xN [z,trace].');
            end

            if isempty(z_trace)
                if numel(z_base) ~= numel(p_raw)
                    error('get_num_notches:LengthMismatch', ...
                        ['Length mismatch (z=%d, trace=%d). No independent trace z-grid ', ...
                         'was provided, so truncation is refused.'], ...
                         numel(z_base), numel(p_raw));
                end
                z = z_base;
                p = p_raw;
            else
                z_trace = z_trace(:);
                p_raw = p_raw(:);
                if numel(z_trace) ~= numel(p_raw)
                    error('get_num_notches:TracePairLengthMismatch', ...
                        'When profile_trace carries [z,trace], both columns must match in length.');
                end
                base_finite_idx = find(isfinite(z_base));
                trace_finite_mask = isfinite(z_trace) & isfinite(p_raw);
                z_trace_valid = z_trace(trace_finite_mask);
                p_trace_valid = p_raw(trace_finite_mask);
                if isempty(z_trace_valid)
                    error('get_num_notches:NoFiniteTraceSamples', ...
                        'The supplied [z,trace] profile contains no finite paired samples.');
                end
                if numel(z_trace_valid) >= 2
                    dz_trace = diff(z_trace_valid);
                    if any(abs(dz_trace) <= eps_z)
                        error('get_num_notches:TraceGridDuplicateZ', ...
                            'The supplied trace z-grid must be duplicate-free within eps_z=%.3e.', eps_z);
                    end
                    if all(dz_trace < -eps_z)
                        z_trace_valid = flipud(z_trace_valid);
                        p_trace_valid = flipud(p_trace_valid);
                    elseif ~all(dz_trace > eps_z)
                        error('get_num_notches:TraceGridNonMonotone', ...
                            ['The supplied trace z-grid must be strictly monotone within eps_z=%.3e. ', ...
                             'Reverse descending traces explicitly or remove scrambled points.'], ...
                            eps_z);
                    end
                end
                a_overlap = z_base(base_finite_idx);
                b_overlap = z_trace_valid;
                [a_sort, ia_sort] = sort(a_overlap(:));
                [b_sort, ib_sort] = sort(b_overlap(:));
                na = numel(a_sort);
                nb = numel(b_sort);
                ia_tmp = zeros(min(na, nb), 1);
                ib_tmp = zeros(min(na, nb), 1);
                k_match = 0;
                i_idx = 1;
                j_idx = 1;
                while i_idx <= na && j_idx <= nb
                    d = a_sort(i_idx) - b_sort(j_idx);
                    if abs(d) <= eps_z
                        k_match = k_match + 1;
                        ia_tmp(k_match) = ia_sort(i_idx);
                        ib_tmp(k_match) = ib_sort(j_idx);
                        i_idx = i_idx + 1;
                        j_idx = j_idx + 1;
                    elseif d < -eps_z
                        i_idx = i_idx + 1;
                    else
                        j_idx = j_idx + 1;
                    end
                end
                ia_local = ia_tmp(1:k_match);
                ib_local = ib_tmp(1:k_match);
                [~, ord_local] = sort(ia_local);
                ia_local = ia_local(ord_local);
                ib_local = ib_local(ord_local);
                ia = base_finite_idx(ia_local);
                ib = ib_local;
                if isempty(ia)
                    error('get_num_notches:NoOverlap', ...
                        'No z-grid overlap found within eps_z=%.3e.', eps_z);
                end
                z = z_base(ia);
                p = p_trace_valid(ib);
            end

            pair_finite = isfinite(z) & isfinite(p);
            z = z(pair_finite);
            p = p(pair_finite);
            if isempty(z)
                num_fils = NaN;
                run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                    run_warn_state, 'CerUPP:GetNumNotches:NoFinitePairs', ...
                    'No finite z/trace pairs remain after alignment. Returning NaN notches.');
                return;
            end

            above = p > cutoff;

            edges = diff([false; above; false]);
            ent_idx = find(edges == 1);
            exit_idx = find(edges == -1) - 1;

            l = numel(z);
            ent_idx(ent_idx < 1 | ent_idx > l) = [];
            exit_idx(exit_idx < 1 | exit_idx > l) = [];

            pair_n = min(numel(ent_idx), numel(exit_idx));
            if pair_n == 0
                return;
            end
            ent_idx = ent_idx(1:pair_n);
            exit_idx = exit_idx(1:pair_n);

            good = ent_idx <= exit_idx;
            if ~all(good)
                run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                    run_warn_state, 'CerUPP:GetNumNotches:BadPairs', ...
                    'Found %d malformed entry/exit pairs; dropping them.', sum(~good));
                ent_idx = ent_idx(good);
                exit_idx = exit_idx(good);
                if isempty(ent_idx)
                    return;
                end
            end

            fil_ent_locations = z(ent_idx).';
            fil_exit_locations = z(exit_idx).';
            fil_lengths = fil_exit_locations - fil_ent_locations;

            good_l = isfinite(fil_lengths) & (fil_lengths >= 0);
            if ~all(good_l)
                run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                    run_warn_state, 'CerUPP:GetNumNotches:BadLengths', ...
                    'Dropping %d segments with invalid lengths.', sum(~good_l));
                fil_ent_locations = fil_ent_locations(good_l);
                fil_exit_locations = fil_exit_locations(good_l);
                fil_lengths = fil_lengths(good_l);
            end

            num_fils = numel(fil_lengths);
        end

        function [ok, err_info] = write_filament_info(filename, filament_diag_spec, L, ...
                num_fils, ent_locations, exit_locations, lengths)
        % WRITE_FILAMENT_INFO Write a labeled filament-summary CSV for one trace family.
        % Scalar rows record the trace label, onset method, reference scalar
        % name/value, threshold fraction, threshold_abs, propagated length,
        % and filament count. Vector rows then record entry locations, exit
        % locations, and lengths with explicit row labels.
        % File-open failure returns ok=false with err_info populated rather
        % than throwing immediately; the caller owns any warning/accounting.

            ok = true;
            err_info = struct('identifier', '', 'message', '');

            file_id= fopen(filename, 'w');

            if file_id < 0
                ok = false;
                err_info.identifier = 'CerUPP:IO:FilamentInfoFileOpenFailed';
                err_info.message = sprintf('Could not open file for writing: %s', filename);
                return
            end
            file_cleanup = onCleanup(@() fclose(file_id)); %#ok<NASGU>

            scalar_rows = { ...
                'trace_label', filament_diag_spec.label; ...
                'detection_method', filament_diag_spec.method; ...
                'reference_scalar_name', filament_diag_spec.reference_scalar_name; ...
                'reference_scalar_value', filament_diag_spec.reference_scalar_value; ...
                'threshold_frac', filament_diag_spec.threshold_frac; ...
                'threshold_abs', filament_diag_spec.threshold_abs; ...
                'distance_to_propagate_m', L; ...
                'num_filaments', num_fils};
            for scalar_idx = 1:size(scalar_rows, 1)
                scalar_key = scalar_rows{scalar_idx, 1};
                scalar_value = scalar_rows{scalar_idx, 2};
                fprintf(file_id, '%s', scalar_key);
                if ischar(scalar_value) || (isstring(scalar_value) && isscalar(scalar_value))
                    fprintf(file_id, ',%s\n', char(string(scalar_value)));
                else
                    fprintf(file_id, ',%.16g\n', scalar_value);
                end
            end

            vectors = {ent_locations, exit_locations, lengths};
            vector_labels = {'entry_locations_m', 'exit_locations_m', 'lengths_m'};
            for i_idx = 1:numel(vectors)
                v = vectors{i_idx};
                if ~isempty(v) && ~isvector(v)
                    error('write_filament_info:ExpectedVector', ...
                          'Expected a vector for row %d; got size %s.', i_idx + 1, mat2str(size(v)));
                end
                v = v(:);
                fprintf(file_id, '%s', vector_labels{i_idx});
                if ~isempty(v)
                    fprintf(file_id, ',%.16g', v);
                end
                fprintf(file_id, '\n');
            end
        end

        function [bw, msg, status] = fwhm_diameter_from_profile(x, prof)
        % FWHM_DIAMETER_FROM_PROFILE Compute a 1D FWHM-style width with diagnostic status output.
        % Returns [bw, msg, status], where recoverable invalid/ambiguous
        % profiles may report bw=NaN with status.recoverable=true instead
        % of erroring (for example size mismatch, complex leakage,
        % non-finite samples, or nonpositive/no-crossing profiles).
        % The live width definition is the first-to-last half-maximum
        % support on the supplied sampled cut. That is intended for compact
        % single-lobe profiles; multi-lobed or edge-clipped cuts can still
        % return a finite support span that is not a geometric beam diameter.

            bw = NaN;
            msg = '';
            status = struct('code', 'ok', 'recoverable', false);
            cap_hi = 1e120;
            x = x(:);
            prof_vec = prof(:);
            if numel(x) ~= numel(prof_vec)
                msg = sprintf('size mismatch (x=%d, prof=%d)', numel(x), numel(prof_vec));
                status.code = 'size_mismatch';
                status.recoverable = true;
                return;
            end
            diag_scan = plot_utils.scan_diag_values(prof_vec, cap_hi, true);
            if diag_scan.complex_leakage
                status.code = 'complex_leakage';
                status.recoverable = true;
                msg = sprintf('complex profile leakage: max|imag|=%.3e exceeds tol=%.3e (width forced NaN)', ...
                    diag_scan.imag_mag, diag_scan.tol_imag);
                return;
            end
            p = diag_scan.real_values;
            if (diag_scan.n_cap > 0) || (diag_scan.n_nan > 0)
                status.code = 'nonfinite_profile';
                status.recoverable = true;
                if diag_scan.n_cap > 0
                    msg = sprintf('non-finite profile samples present (%d Inf/huge; width forced NaN)', diag_scan.n_cap);
                else
                    msg = sprintf('non-finite profile samples present (%d NaN; width forced NaN)', diag_scan.n_nan);
                end
                return;
            end
            pmax = max(p);
            if ~(pmax > 0)
                msg = 'nonpositive peak';
                status.code = 'nonpositive_peak';
                status.recoverable = true;
                return;
            end
            half = 0.5*pmax;
            above_half = (p >= half);
            crossing_idx = find(above_half);
            if isempty(crossing_idx)
                msg = 'no half-max crossing found';
                status.code = 'no_half_max_crossing';
                status.recoverable = true;
                return;
            end
            i1 = crossing_idx(1);
            i2 = crossing_idx(end);

            if i1 > 1
                x0 = x(i1-1); x1 = x(i1);
                y0 = p(i1-1); y1 = p(i1);
                if y1 ~= y0
                    x_l = x0 + (half - y0)*(x1 - x0)/(y1 - y0);
                else
                    x_l = x1;
                end
            else
                x_l = x(i1);
            end

            if i2 < numel(p)
                x0 = x(i2); x1 = x(i2+1);
                y0 = p(i2); y1 = p(i2+1);
                if y1 ~= y0
                    x_r = x0 + (half - y0)*(x1 - x0)/(y1 - y0);
                else
                    x_r = x0;
                end
            else
                x_r = x(i2);
            end

            bw = x_r - x_l;
            if ~(isfinite(bw) && bw >= 0)
                bw = NaN;
                msg = 'invalid crossing result';
                status.code = 'invalid_crossing_result';
                status.recoverable = true;
                return;
            end
            status.code = 'ok';
            status.recoverable = false;
        end

        function [fluence_xy_bands, td_oa_bands, td_bc_bands, td_maxperp_bands] = build_multi_band_time_diagnostics( ...
                a_fft_stored, mask_4d, band_weight_xy_stack, t, delta_t, fluence_use_parseval, ix_axis0, iy_axis0, ix_bc, iy_bc, request_in, parseval_time_grid_ok, spectral_power_raw)
        % BUILD_MULTI_BAND_TIME_DIAGNOSTICS Shared streamed multi-band diagnostic reducer.
        % mask_4d may be full [Nx Ny Nt Nbands] or spectral-only [1 1 Nt Nbands]. request_in selects the
        % per-band fluence, td_oa, td_bc, and td_maxperp products.
        % Returns fluence_xy_bands with shape [Nx Ny Nbands] when any
        % fluence request is enabled, plus td_oa_bands, td_bc_bands, and
        % td_maxperp_bands with shape [Nbands Nt] for enabled time-domain
        % families. Disabled output families return [].

            if nargin < 11
                request_in = [];
            end
            if nargin < 12
                parseval_time_grid_ok = [];
            end
            if nargin < 13
                spectral_power_raw = [];
            end
            band_request_ctx = ...
                filament_diagnostics_utils.prepare_multi_band_diag_request_ctx_local( ...
                    a_fft_stored, mask_4d, band_weight_xy_stack, ...
                    t, delta_t, fluence_use_parseval, ...
                    ix_axis0, iy_axis0, ix_bc, iy_bc, ...
                    request_in, parseval_time_grid_ok);
            mask_4d = band_request_ctx.mask_4d;
            fluence_xy_bands = [];
            td_oa_bands = [];
            td_bc_bands = [];
            td_maxperp_bands = [];
            if any(band_request_ctx.need_fluence_band)
                fluence_xy_bands = zeros( ...
                    band_request_ctx.nx_local, band_request_ctx.ny_local, ...
                    band_request_ctx.n_bands, 'like', real(a_fft_stored(1)));
            end
            if band_request_ctx.need_td_oa_family
                td_oa_bands = nan(band_request_ctx.n_bands, band_request_ctx.nt_local, ...
                    'like', real(a_fft_stored(1)));
            end
            if band_request_ctx.need_td_bc_family
                td_bc_bands = nan(band_request_ctx.n_bands, band_request_ctx.nt_local, ...
                    'like', real(a_fft_stored(1)));
            end
            if band_request_ctx.need_td_maxperp_family
                td_maxperp_bands = zeros(band_request_ctx.n_bands, band_request_ctx.nt_local, ...
                    'like', real(a_fft_stored(1)));
            end
            if ~any(band_request_ctx.need_fluence_band) && ~any(band_request_ctx.need_time_band)
                return;
            end
            for band_idx = 1:band_request_ctx.n_bands
                request = band_request_ctx.request_stack(band_idx);
                if ~(request.fluence || request.td_oa || request.td_bc || request.td_maxperp)
                    continue;
                end
                need_full_time_band = request.td_maxperp || ...
                    (~band_request_ctx.use_parseval_effective && request.fluence);
                band_weight_xy = filament_diagnostics_utils.resolve_band_weight_xy_local( ...
                    band_request_ctx, band_idx);
                intens_band_code = [];
                intens_band_weighted = [];
                if need_full_time_band
                    masked_band = a_fft_stored .* mask_4d(:, :, :, band_idx);
                    time_band = ifft(masked_band, [], 3);
                    intens_band_code = real(time_band .* conj(time_band));
                    intens_band_weighted = band_weight_xy .* intens_band_code;
                end
                if request.fluence
                    if band_request_ctx.use_parseval_effective
                        if ~isempty(intens_band_code)
                            % Reuse the already reconstructed band trace and preserve
                            % exact Parseval scaling via the uniform-grid time sum.

                            fluence_xy_bands(:, :, band_idx) = ...
                                band_weight_xy .* band_request_ctx.delta_t_like .* sum(intens_band_code, 3);
                        else
                            if ~isempty(spectral_power_raw)
                                fluence_xy_bands(:, :, band_idx) = ...
                                    band_diagnostics_utils.build_weighted_fluence_from_masked_spectrum( ...
                                    a_fft_stored, band_weight_xy, t, delta_t, ...
                                    true, [], parseval_time_grid_ok, spectral_power_raw, ...
                                    mask_4d(:, :, :, band_idx));
                            else
                                masked_band = a_fft_stored .* mask_4d(:, :, :, band_idx);
                                fluence_xy_bands(:, :, band_idx) = ...
                                    band_diagnostics_utils.build_weighted_fluence_from_masked_spectrum( ...
                                    masked_band, band_weight_xy, t, delta_t, ...
                                    true, [], parseval_time_grid_ok, [], []);
                            end
                        end
                    else
                        fluence_xy_bands(:, :, band_idx) = trapz(t, intens_band_weighted, 3);
                    end
                end
                if request.td_oa
                    if band_request_ctx.axis_sample_ok
                        if ~isempty(intens_band_weighted)
                            td_oa_bands(band_idx, :) = squeeze( ...
                                intens_band_weighted(ix_axis0, iy_axis0, :)).';
                        else
                            td_oa_bands(band_idx, :) = ...
                                filament_diagnostics_utils.build_weighted_band_point_trace_from_spectrum_local( ...
                                a_fft_stored, mask_4d, band_idx, ...
                                ix_axis0, iy_axis0, band_weight_xy(ix_axis0, iy_axis0));
                        end
                    end
                end
                if request.td_bc
                    if band_request_ctx.beamcenter_sample_ok
                        if ~isempty(intens_band_weighted)
                            td_bc_bands(band_idx, :) = squeeze(intens_band_weighted(ix_bc, iy_bc, :)).';
                        else
                            td_bc_bands(band_idx, :) = ...
                                filament_diagnostics_utils.build_weighted_band_point_trace_from_spectrum_local( ...
                                a_fft_stored, mask_4d, band_idx, ...
                                ix_bc, iy_bc, band_weight_xy(ix_bc, iy_bc));
                        end
                    end
                end
                if request.td_maxperp
                    td_maxperp_bands(band_idx, :) = max( ...
                        reshape(intens_band_weighted, [], band_request_ctx.nt_local), [], 1);
                end
            end
        end

        function band_request_ctx = prepare_multi_band_diag_request_ctx_local( ...
                a_fft_stored, mask_4d, band_weight_xy_stack, ...
                t, delta_t, fluence_use_parseval, ...
                ix_axis0, iy_axis0, ix_bc, iy_bc, request_in, parseval_time_grid_ok)
        % Normalize request shape, mask shape, and sample-location policy
        % once before the per-band emission loop runs.

            if ndims(mask_4d) == 3
                mask_4d = reshape(mask_4d, size(mask_4d, 1), size(mask_4d, 2), size(mask_4d, 3), 1);
            elseif ndims(mask_4d) ~= 4
                error('CerUPP:InvalidBandMaskStack', ...
                    ['mask_4d must have shape [Nx Ny Nt Nbands] (or singleton-band [Nx Ny Nt] / [1 1 Nt]); ', ...
                     'got ndims=%d.'], ndims(mask_4d));
            end
            n_bands = size(mask_4d, 4);
            request_stack = normalize_multi_band_diag_request_local(request_in, n_bands);
            [nx_local, ny_local, nt_local] = size(a_fft_stored);
            if ~ismember(size(mask_4d, 1), [1, nx_local]) || ...
                    ~ismember(size(mask_4d, 2), [1, ny_local]) || ...
                    ~isequal(size(mask_4d, 3), nt_local)
                error('CerUPP:InvalidBandMaskStackShape', ...
                    'mask_4d must have shape [%d %d %d Nbands] or [1 1 %d Nbands]; got %s.', ...
                    nx_local, ny_local, nt_local, nt_local, mat2str(size(mask_4d)));
            end
            band_weight_ndims = ndims(band_weight_xy_stack);
            if band_weight_ndims == 2
                if ~isequal(size(band_weight_xy_stack), [nx_local, ny_local])
                    error('CerUPP:InvalidBandDiagWeightShape', ...
                        'band_weight_xy_stack must have shape [%d %d] or [%d %d Nbands]; got %s.', ...
                        nx_local, ny_local, nx_local, ny_local, mat2str(size(band_weight_xy_stack)));
                end
                single_band_weight_map = true;
            elseif band_weight_ndims == 3
                if ~isequal(size(band_weight_xy_stack, 1), nx_local) || ...
                        ~isequal(size(band_weight_xy_stack, 2), ny_local) || ...
                        ~isequal(size(band_weight_xy_stack, 3), n_bands)
                    error('CerUPP:InvalidBandDiagWeightShape', ...
                        'band_weight_xy_stack must have shape [%d %d] or [%d %d %d]; got %s.', ...
                        nx_local, ny_local, nx_local, ny_local, n_bands, ...
                        mat2str(size(band_weight_xy_stack)));
                end
                single_band_weight_map = false;
            else
                error('CerUPP:InvalidBandDiagWeightShape', ...
                    'band_weight_xy_stack must have ndims 2 or 3; got ndims=%d.', ...
                    band_weight_ndims);
            end

            need_fluence_band = false(1, n_bands);
            need_time_band = false(1, n_bands);
            need_td_oa_family = false;
            need_td_bc_family = false;
            need_td_maxperp_family = false;
            for band_idx = 1:n_bands
                request = request_stack(band_idx);
                need_fluence_band(band_idx) = request.fluence;
                need_td_oa_family = need_td_oa_family || request.td_oa;
                need_td_bc_family = need_td_bc_family || request.td_bc;
                need_td_maxperp_family = need_td_maxperp_family || request.td_maxperp;
            end
            if any(need_fluence_band)
                use_parseval_effective = resolve_parseval_effective_local( ...
                    t, delta_t, fluence_use_parseval, parseval_time_grid_ok);
            else
                use_parseval_effective = false;
            end
            for band_idx = 1:n_bands
                request = request_stack(band_idx);
                need_time_band(band_idx) = request.td_oa || request.td_bc || request.td_maxperp || ...
                    (~use_parseval_effective && request.fluence);
            end

            band_request_ctx = struct( ...
                'mask_4d', mask_4d, ...
                'request_stack', request_stack, ...
                'n_bands', n_bands, ...
                'nx_local', nx_local, ...
                'ny_local', ny_local, ...
                'nt_local', nt_local, ...
                'need_fluence_band', need_fluence_band, ...
                'need_time_band', need_time_band, ...
                'need_td_oa_family', logical(need_td_oa_family), ...
                'need_td_bc_family', logical(need_td_bc_family), ...
                'need_td_maxperp_family', logical(need_td_maxperp_family), ...
                'band_weight_xy_stack', band_weight_xy_stack, ...
                'single_band_weight_map', logical(single_band_weight_map), ...
                'use_parseval_effective', logical(use_parseval_effective), ...
                'axis_sample_ok', isscalar(ix_axis0) && isscalar(iy_axis0) && ...
                    isfinite(ix_axis0) && isfinite(iy_axis0) && ...
                    (ix_axis0 >= 1) && (ix_axis0 <= nx_local) && ...
                    (iy_axis0 >= 1) && (iy_axis0 <= ny_local) && ...
                    (ix_axis0 == round(ix_axis0)) && (iy_axis0 == round(iy_axis0)), ...
                'beamcenter_sample_ok', isscalar(ix_bc) && isscalar(iy_bc) && ...
                    isfinite(ix_bc) && isfinite(iy_bc) && ...
                    (ix_bc >= 1) && (ix_bc <= nx_local) && ...
                    (iy_bc >= 1) && (iy_bc <= ny_local) && ...
                    (ix_bc == round(ix_bc)) && (iy_bc == round(iy_bc)), ...
                'delta_t_like', cast(delta_t, 'like', real(a_fft_stored(1))));
        end

        function band_weight_xy = resolve_band_weight_xy_local(band_request_ctx, band_idx)
            if band_request_ctx.single_band_weight_map
                band_weight_xy = band_request_ctx.band_weight_xy_stack;
            else
                band_weight_xy = band_request_ctx.band_weight_xy_stack(:, :, band_idx);
            end
        end

        function weighted_trace = build_weighted_band_point_trace_from_spectrum_local( ...
                a_fft_stored, mask_4d, band_idx, ix_sample, iy_sample, sample_weight)
        % Rebuild one weighted band-limited time trace without touching the full x-y cube.

            spectral_line = reshape(a_fft_stored(ix_sample, iy_sample, :), 1, []);
            if size(mask_4d, 1) == 1
                mask_line = reshape(mask_4d(1, 1, :, band_idx), 1, []);
            else
                mask_line = reshape(mask_4d(ix_sample, iy_sample, :, band_idx), 1, []);
            end
            spectral_line = spectral_line .* cast(mask_line, 'like', spectral_line);
            time_line = ifft(spectral_line, [], 2);
            weighted_trace = cast(sample_weight, 'like', real(time_line)) .* ...
                real(time_line .* conj(time_line));
        end

        function [tf, status] = time_grid_supports_parseval_fluence(t, delta_t)
        % TIME_GRID_SUPPORTS_PARSEVAL_FLUENCE Check the Parseval shortcut contract.
        % Returns a boolean capability flag plus an optional status struct
        % so callers can distinguish invalid inputs from a valid grid that
        % simply does not support the shortcut. STATUS fields are
        % valid_input, capable, reason, dt_ref, and dt_tol; REASON
        % currently uses invalid_delta_t, invalid_t,
        % insufficient_samples, degenerate_spacing,
        % nonuniform_spacing, delta_t_mismatch, and supported.

            tf = false;
            status = struct( ...
                'valid_input', false, ...
                'capable', false, ...
                'reason', 'invalid_delta_t', ...
                'dt_ref', NaN, ...
                'dt_tol', NaN);
            if nargin < 2 || ~isscalar(delta_t) || ~isfinite(delta_t) || ~(delta_t > 0)
                return;
            end
            status.reason = 'invalid_t';
            if nargin < 1 || isempty(t) || ~isnumeric(t) || ~isreal(t) || ~isvector(t)
                return;
            end
            t_row = double(t(:)).';
            if any(~isfinite(t_row))
                status.reason = 'invalid_t';
                return;
            end
            if numel(t_row) < 2
                status.reason = 'insufficient_samples';
                return;
            end
            dt_samples = diff(t_row);
            if isempty(dt_samples) || any(~isfinite(dt_samples))
                status.reason = 'invalid_t';
                return;
            end
            if any(dt_samples == 0)
                status.reason = 'degenerate_spacing';
                return;
            end
            status.valid_input = true;
            dt_ref = dt_samples(1);
            dt_scale = max([abs(dt_ref), abs(double(delta_t)), realmin('double')]);
            dt_tol = max(100 * eps(dt_scale), 1e-9 * dt_scale);
            status.dt_ref = dt_ref;
            status.dt_tol = dt_tol;
            if any(abs(dt_samples - dt_ref) > dt_tol)
                status.reason = 'nonuniform_spacing';
                return;
            end
            if abs(double(delta_t) - dt_ref) > dt_tol
                status.reason = 'delta_t_mismatch';
                return;
            end
            tf = true;
            status.capable = true;
            status.reason = 'supported';
        end
    end

end

function onset_window_policy = filament_diagnostics_utils_onset_window_policy(z_samples)
% Keep one shared physical-z smoothing policy across onset-labeled families.

    target_span_m = 3e-4;
    onset_window_policy = struct( ...
        'rule_name', 'physical_z_span_v1', ...
        'supported', false, ...
        'reason', 'too_few_z_samples', ...
        'target_span_m', target_span_m, ...
        'effective_span_m', NaN, ...
        'median_dz_m', NaN, ...
        'minimum_supported_median_dz_m', 0.5 * target_span_m, ...
        'window_samples', NaN);
    if nargin < 1 || isempty(z_samples)
        onset_window_policy.reason = 'missing_z_samples';
        return;
    end

    z_col = double(z_samples(:));
    z_col = z_col(isfinite(z_col));
    if numel(z_col) < 3
        onset_window_policy.reason = 'too_few_finite_z_samples';
        return;
    end

    dz_samples = diff(z_col);
    dz_samples = dz_samples(isfinite(dz_samples) & (dz_samples > 0));
    if numel(dz_samples) < 2
        onset_window_policy.reason = 'nonincreasing_z_support';
        return;
    end

    median_dz_m = median(dz_samples);
    onset_window_policy.median_dz_m = median_dz_m;
    if ~isfinite(median_dz_m) || (median_dz_m <= 0)
        onset_window_policy.reason = 'invalid_median_dz';
        return;
    end

    half_window_steps = floor(target_span_m / (2 * median_dz_m));
    if half_window_steps < 1
        onset_window_policy.supported = true;
        onset_window_policy.reason = 'coarse_z_spacing_reduced_window';
        onset_window_policy.window_samples = 3;
        onset_window_policy.effective_span_m = 2 * median_dz_m;
        return;
    end

    window_samples = 2 * half_window_steps + 1;
    max_odd_samples = numel(z_col);
    if mod(max_odd_samples, 2) == 0
        max_odd_samples = max_odd_samples - 1;
    end
    window_samples = min(window_samples, max_odd_samples);
    if window_samples < 3
        onset_window_policy.reason = 'too_few_z_samples';
        onset_window_policy.window_samples = window_samples;
        onset_window_policy.effective_span_m = max(0, (window_samples - 1) * median_dz_m);
        return;
    end

    onset_window_policy.supported = true;
    onset_window_policy.reason = 'ok';
    onset_window_policy.window_samples = window_samples;
    onset_window_policy.effective_span_m = (window_samples - 1) * median_dz_m;
end

function onset_indicator_specs = fil_diag_build_priority_onset_specs_impl( ...
    store_max_rho, store_fluence_xy_visible, store_fpeak_vis, ...
    store_fluence_vis_onaxis, valid, ix_oa, iy_oa)
% Ordered fallback list for detected-onset indicator selection.

    onset_indicator_specs = repmat(struct( ...
        'label', '', 'enabled', false, 'trace', [], 'sample_idx', []), 4, 1);
    onset_indicator_specs(1).label = 'rho_MAXPERP';
    onset_indicator_specs(2).label = 'Fvis_MAXPERP';
    onset_indicator_specs(3).label = 'rho_ONAXIS';
    onset_indicator_specs(4).label = 'Fvis_ONAXIS';

    if ~isempty(store_max_rho)
        valid_rho = fil_diag_filter_valid_indices_local(valid, size(store_max_rho, 3));
        if ~isempty(valid_rho)
            onset_indicator_specs(1).enabled = true;
            onset_indicator_specs(1).sample_idx = valid_rho;
            onset_indicator_specs(1).trace = squeeze(max(max(store_max_rho(:, :, valid_rho), [], 1), [], 2));
        end
        if fil_diag_have_onaxis_index_local(store_max_rho, valid_rho, ix_oa, iy_oa)
            onset_indicator_specs(3).enabled = true;
            onset_indicator_specs(3).sample_idx = valid_rho;
            onset_indicator_specs(3).trace = squeeze(store_max_rho(ix_oa, iy_oa, valid_rho));
        end
    end
    valid_fpeak = fil_diag_filter_valid_indices_local(valid, numel(store_fpeak_vis));
    if ~isempty(store_fpeak_vis) && ~isempty(valid_fpeak)
        onset_indicator_specs(2).enabled = true;
        onset_indicator_specs(2).sample_idx = valid_fpeak;
        onset_indicator_specs(2).trace = store_fpeak_vis(valid_fpeak);
    elseif ~isempty(store_fluence_xy_visible)
        valid_fvis = fil_diag_filter_valid_indices_local(valid, size(store_fluence_xy_visible, 3));
        if ~isempty(valid_fvis)
            onset_indicator_specs(2).enabled = true;
            onset_indicator_specs(2).sample_idx = valid_fvis;
            onset_indicator_specs(2).trace = squeeze(max(max(store_fluence_xy_visible(:, :, valid_fvis), [], 1), [], 2));
        end
    end
    valid_fvis_onaxis = fil_diag_filter_valid_indices_local(valid, numel(store_fluence_vis_onaxis));
    if ~isempty(store_fluence_vis_onaxis) && ~isempty(valid_fvis_onaxis)
        onset_indicator_specs(4).enabled = true;
        onset_indicator_specs(4).sample_idx = valid_fvis_onaxis;
        onset_indicator_specs(4).trace = store_fluence_vis_onaxis(valid_fvis_onaxis);
    else
        valid_fvis = fil_diag_filter_valid_indices_local(valid, size(store_fluence_xy_visible, 3));
        if ~isempty(store_fluence_xy_visible) && fil_diag_have_onaxis_index_local( ...
            store_fluence_xy_visible, valid_fvis, ix_oa, iy_oa)
            onset_indicator_specs(4).enabled = true;
            onset_indicator_specs(4).sample_idx = valid_fvis;
            onset_indicator_specs(4).trace = squeeze(store_fluence_xy_visible(ix_oa, iy_oa, valid_fvis));
        end
    end
end

function tf = fil_diag_have_onaxis_index_local(volume_data, valid, ix_oa, iy_oa)
% Check whether on-axis indexing is available for a priority-trace volume.

    tf = false;
    if isempty(volume_data) || isempty(valid) || isempty(ix_oa) || isempty(iy_oa)
        return;
    end
    if ~(isscalar(ix_oa) && isnumeric(ix_oa) && isfinite(ix_oa) && ...
            isscalar(iy_oa) && isnumeric(iy_oa) && isfinite(iy_oa))
        return;
    end
    ix_oa = double(ix_oa);
    iy_oa = double(iy_oa);
    if (ix_oa < 1) || (iy_oa < 1) || (ix_oa ~= round(ix_oa)) || (iy_oa ~= round(iy_oa))
        return;
    end
    vol_sz = size(volume_data);
    if numel(vol_sz) < 3
        return;
    end
    valid = double(valid(:));
    if any(~isfinite(valid)) || any(valid < 1) || any(valid ~= round(valid)) || any(valid > vol_sz(3))
        return;
    end
    tf = (ix_oa <= vol_sz(1)) && (iy_oa <= vol_sz(2));
end

function valid_out = fil_diag_filter_valid_indices_local(valid_in, max_len)
% Keep only finite in-range integer sample indices for one trace family.

    valid_out = [];
    if isempty(valid_in) || isempty(max_len) || ~isfinite(max_len) || (max_len < 1)
        return;
    end
    valid_out = double(valid_in(:));
    keep_mask = isfinite(valid_out) & (valid_out >= 1) & ...
        (valid_out <= double(max_len)) & (valid_out == round(valid_out));
    valid_out = valid_out(keep_mask);
end

function status = filament_diagnostics_utils_make_status_local(value_in, default_code)
% Canonical onset-status schema owner.

    if nargin < 2 || isempty(default_code)
        default_code = 'ok';
    end
    code_txt = lower(strtrim(char(string(default_code))));
    if isempty(code_txt)
        code_txt = 'ok';
    end
    if isstruct(value_in)
        if isfield(value_in, 'status') && isstruct(value_in.status)
            value_in = value_in.status;
        end
        if isstruct(value_in) && isfield(value_in, 'code')
            value_in = value_in.code;
        else
            value_in = '';
        end
    end
    if ischar(value_in) || (isstring(value_in) && isscalar(value_in))
        candidate = lower(strtrim(char(string(value_in))));
        if ~isempty(candidate)
            code_txt = candidate;
        end
    end
    status = struct( ...
        'ok', strcmp(code_txt, 'ok'), ...
        'code', code_txt);
end

function det = filament_diagnostics_utils_build_onset_det_local( ...
    method_name, label, threshold, z_onset, onset_idx, status_code_txt)
% Build one canonical internal onset-detection struct.

    if nargin < 1 || isempty(method_name)
        method_name = 'unknown';
    end
    if nargin < 2 || isempty(label)
        label = '';
    end
    if nargin < 3 || isempty(threshold)
        threshold = NaN;
    end
    if nargin < 4 || isempty(z_onset)
        z_onset = NaN;
    end
    if nargin < 5 || isempty(onset_idx)
        onset_idx = NaN;
    end
    if nargin < 6 || isempty(status_code_txt)
        status_code_txt = 'ok';
    end
    det = struct( ...
        'threshold', threshold, ...
        'z_onset', z_onset, ...
        'label', label, ...
        'onset_idx', onset_idx, ...
        'status', filament_diagnostics_utils_make_status_local(status_code_txt, 'ok'), ...
        'method', char(string(method_name)));
end

function det = filament_diagnostics_utils_first_decrease_after_threshold(trace_vec, z_vec, threshold_basis_value, frac_threshold, label, w)
% First post-threshold decrease in the smoothed trace after amplitude-threshold crossing.

    if nargin < 5 || isempty(label)
        label = '';
    end
    if nargin < 6
        w = [];
    end

    det = filament_diagnostics_utils_detect_threshold_crossing_core_impl( ...
        trace_vec, z_vec, threshold_basis_value, frac_threshold, label, ...
        'first_decrease_after_threshold', false);

    trace_col = trace_vec(:);
    z_col = z_vec(:);
    nz = numel(z_col);
    if numel(trace_col) ~= nz || nz < 3
        det.status = filament_diagnostics_utils_make_status_local('invalid_inputs_for_first_decrease');
        det.z_onset = NaN;
        det.onset_idx = NaN;
        return;
    end

    finite_trace_samples = isfinite(trace_col) & isfinite(z_col);
    if nnz(finite_trace_samples) < 3
        det.status = filament_diagnostics_utils_make_status_local('too_few_finite_samples_for_first_decrease');
        det.z_onset = NaN;
        det.onset_idx = NaN;
        return;
    end

    threshold = det.threshold;
    if ~isscalar(threshold) || ~isfinite(threshold)
        det.status = filament_diagnostics_utils_make_status_local('invalid_threshold_for_first_decrease');
        det.z_onset = NaN;
        det.onset_idx = NaN;
        return;
    end

    w_use = filament_diagnostics_utils_onset_detect_window_impl(nz, w);
    trace_use = trace_col;
    if w_use > 1
        half_left = floor((w_use - 1) / 2);
        half_right = ceil((w_use - 1) / 2);
        idx = (1:nz).';
        lo = max(1, idx - half_left);
        hi = min(nz, idx + half_right);
        finite_trace_mask = isfinite(trace_use);
        finite_trace_sum = zeros(nz, 1);
        finite_trace_sum(finite_trace_mask) = double(trace_use(finite_trace_mask));
        cs = [0; cumsum(finite_trace_sum)];
        cc = [0; cumsum(double(finite_trace_mask))];
        window_sum = cs(hi + 1) - cs(lo);
        window_count = cc(hi + 1) - cc(lo);
        trace_use(:) = NaN;
        valid_window = (window_count > 0);
        if any(valid_window)
            trace_use(valid_window) = cast(window_sum(valid_window) ./ window_count(valid_window), 'like', trace_col);
        end
    end

    smoothed_support = isfinite(trace_use) & isfinite(z_col);
    if nnz(smoothed_support) < 3
        det.status = filament_diagnostics_utils_make_status_local('too_few_smoothed_samples_for_first_decrease');
        det.z_onset = NaN;
        det.onset_idx = NaN;
        return;
    end

    gate_idx = find(isfinite(trace_use) & isfinite(z_col) & (trace_use > threshold), 1, 'first');
    if isempty(gate_idx) || gate_idx >= nz
        det.status = filament_diagnostics_utils_make_status_local('never_exceeds_threshold');
        det.z_onset = NaN;
        det.onset_idx = NaN;
        return;
    end

    dec_metric = -diff(trace_use);
    z_diff = z_col(1:end-1);
    if gate_idx > 1
        dec_metric(1:gate_idx-1) = -Inf;
    end
    bad_diff = ~isfinite(dec_metric) | ~isfinite(z_diff);
    dec_metric(bad_diff) = -Inf;

    det_dec = filament_diagnostics_utils_detect_threshold_crossing_core_impl( ...
        dec_metric, z_diff, 1, 0, sprintf('%s_firstdec', label));
    det_dec_idx = struct_utils.opt_struct_field(det_dec, 'onset_idx', NaN);
    if isstruct(det_dec) && isfield(det_dec, 'z_onset') && isfinite(det_dec.z_onset) && ...
            isfinite(det_dec_idx)
        det.onset_idx = min(nz, double(det_dec_idx) + 1);
        det.z_onset = z_col(det.onset_idx);
        det.status = filament_diagnostics_utils_make_status_local('ok');
    else
        det.status = filament_diagnostics_utils_make_status_local( ...
            det_dec, 'first_decrease_not_found_after_threshold');
        det.z_onset = NaN;
        det.onset_idx = NaN;
    end
end

function w_use = filament_diagnostics_utils_onset_detect_window_impl(nz, w_in)
% Resolve smoothing window for onset adapters.

    if ~isempty(w_in) && isnumeric(w_in) && isfinite(w_in) && (w_in >= 1)
        w_use = round(double(w_in));
    else
        w_use = filament_diagnostics_utils_default_onset_window_local(nz);
    end
    w_use = max(1, min(nz, w_use));
end

function w_default = filament_diagnostics_utils_default_onset_window_local(nz)
% Keep one shared 5/7/9 default ladder for onset smoothing when no explicit window is supplied.

    w_default = 5;
    if nz >= 21
        w_default = 9;
    elseif nz >= 11
        w_default = 7;
    end
end

function detected_onset = filament_diagnostics_utils_detect_threshold_crossing_core_impl( ...
    data_trace, store_z, threshold_basis_value, frac_threshold, label, method_name, attach_trace)
% Threshold-crossing core returning one status-bearing onset struct.

    if nargin < 5
        label = '';
    end
    if nargin < 6 || isempty(method_name)
        method_name = 'threshold_crossing';
    end
    if nargin < 7 || isempty(attach_trace)
        attach_trace = false;
    end
    if isempty(data_trace) || isempty(store_z) || isempty(threshold_basis_value) || isempty(frac_threshold)
        detected_onset = filament_diagnostics_utils_build_onset_det_local( ...
            method_name, label, NaN, NaN, NaN, 'missing_inputs');
        detected_onset = filament_diagnostics_utils_finalize_onset_det_local( ...
            detected_onset, attach_trace, data_trace);
        return;
    end

    data_trace = data_trace(:);
    store_z = store_z(:);
    [trace_grid_status, ~] = filament_diagnostics_utils_validate_trace_grid_local( ...
        store_z, data_trace, 1);
    if ~strcmp(trace_grid_status, 'ok')
        detected_onset = filament_diagnostics_utils_build_onset_det_local( ...
            method_name, label, frac_threshold .* threshold_basis_value, NaN, NaN, trace_grid_status);
        detected_onset = filament_diagnostics_utils_finalize_onset_det_local( ...
            detected_onset, attach_trace, data_trace);
        return;
    end

    threshold = frac_threshold .* threshold_basis_value;
    if ~isscalar(threshold) || ~isfinite(threshold)
        detected_onset = filament_diagnostics_utils_build_onset_det_local( ...
            method_name, label, threshold, NaN, NaN, 'invalid_threshold');
        detected_onset = filament_diagnostics_utils_finalize_onset_det_local( ...
            detected_onset, attach_trace, data_trace);
        return;
    end

    valid = isfinite(data_trace) & isfinite(store_z);
    if ~any(valid)
        detected_onset = filament_diagnostics_utils_build_onset_det_local( ...
            method_name, label, threshold, NaN, NaN, 'no_finite_overlap');
        detected_onset = filament_diagnostics_utils_finalize_onset_det_local( ...
            detected_onset, attach_trace, data_trace);
        return;
    end
    z_valid = store_z(valid);
    eps_z = max(eps(max(abs(z_valid))), 1e-15);
    if (max(z_valid) - min(z_valid)) <= eps_z
        detected_onset = filament_diagnostics_utils_build_onset_det_local( ...
            method_name, label, threshold, NaN, NaN, 'degenerate_z_overlap');
        detected_onset = filament_diagnostics_utils_finalize_onset_det_local( ...
            detected_onset, attach_trace, data_trace);
        return;
    end
    trace_ok = data_trace;
    trace_ok(~valid) = -Inf;

    onset_idx = find(trace_ok > threshold, 1, 'first');
    z_onset = NaN;
    if ~isempty(onset_idx)
        z_onset = store_z(onset_idx);
    end

    detected_onset = filament_diagnostics_utils_build_onset_det_local( ...
        method_name, label, threshold, z_onset, onset_idx, 'ok');
    detected_onset = filament_diagnostics_utils_finalize_onset_det_local( ...
        detected_onset, attach_trace, data_trace);
end

function [det, run_warn_state] = filament_diagnostics_utils_detect_slope_to_peak_impl(z_vec, trace_vec, w_in, label, run_warn_state)
% Canonical internal slope_to_peak detector returning the shared onset-det struct.

    det = filament_diagnostics_utils_build_onset_det_local( ...
        'slope_to_peak', '', NaN, NaN, NaN, 'slope_onset_not_found');
    det.peak_idx = NaN;
    det.window = NaN;
    if nargin < 3
        w_in = [];
    end
    if nargin < 5 || isempty(run_warn_state)
        run_warn_state = struct();
    end

    % Input normalization
    z_vec = z_vec(:);
    trace_vec = trace_vec(:);
    [trace_grid_status, dz_tol] = filament_diagnostics_utils_validate_trace_grid_local( ...
        z_vec, trace_vec, 3);
    nz = numel(z_vec);
    switch trace_grid_status
        case 'ok'
        case 'length_mismatch'
            run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                run_warn_state, 'CerUPP:OnsetFromTrace:LengthMismatch', ...
                'z_vec and trace_vec must have equal lengths; returning NaN.');
            det.status = filament_diagnostics_utils_make_status_local(trace_grid_status);
            return;
        case 'nonfinite_z'
            run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                run_warn_state, 'CerUPP:OnsetFromTrace:NonFiniteZ', ...
                'z_vec contains non-finite values; returning NaN.');
            det.status = filament_diagnostics_utils_make_status_local(trace_grid_status);
            return;
        case 'nonincreasing_z'
            run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                run_warn_state, 'CerUPP:OnsetFromTrace:NonIncreasingZ', ...
                'z_vec must be strictly increasing (no repeats/reversal); returning NaN.');
            det.status = filament_diagnostics_utils_make_status_local(trace_grid_status);
            return;
        case 'degenerate_spacing'
            run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                run_warn_state, 'CerUPP:OnsetFromTrace:DegenerateZSpacing', ...
                'z_vec has degenerate near-zero spacing (tol=%.3e); returning NaN.', dz_tol);
            det.status = filament_diagnostics_utils_make_status_local(trace_grid_status);
            return;
        case 'too_few_samples'
            run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
                run_warn_state, 'CerUPP:OnsetFromTrace:TooFewSamples', ...
                'Need at least 3 samples for meaningful onset detection; returning NaN.');
            det.status = filament_diagnostics_utils_make_status_local(trace_grid_status);
            return;
        otherwise
            det.status = filament_diagnostics_utils_make_status_local(trace_grid_status);
            return;
    end

    if ~any(trace_vec > 0)
        run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
            run_warn_state, 'CerUPP:OnsetFromTrace:NoPositiveSignal', ...
            'Trace has no positive samples; returning NaN.');
        det.status = filament_diagnostics_utils_make_status_local('no_positive_signal');
        return;
    end

    w = filament_diagnostics_utils_default_onset_window_local(nz);
    if isnumeric(w_in) && isscalar(w_in) && isfinite(w_in) && w_in >= 1
        w = max(1, round(w_in));
    end
    if nargin >= 4 && ~isempty(label)
        det.label = label;
    end
    w = min(w, nz);
    det.window = w;

    y_col = trace_vec(:);
    if w <= 1
        y_s = y_col;
    else
        half_left = floor((w - 1) / 2);
        half_right = ceil((w - 1) / 2);
        idx = (1:nz).';
        lo = max(1, idx - half_left);
        hi = min(nz, idx + half_right);
        cs = [0; cumsum(double(y_col))];
        window_sum = cs(hi + 1) - cs(lo);
        window_len = double(hi - lo + 1);
        y_s = cast(window_sum ./ window_len, 'like', y_col);
    end

    [~, j_peak] = max(y_s);
    j_peak = max(2, min(j_peak, nz));
    det.peak_idx = j_peak;

    dydz = gradient(y_s, z_vec);
    if ~any(isfinite(dydz))
        run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
            run_warn_state, 'CerUPP:OnsetFromTrace:NoFiniteSlope', ...
            'No finite slope samples after smoothing; returning NaN.');
        det.status = filament_diagnostics_utils_make_status_local('no_finite_slope');
        return;
    end

    j_search = max(2, j_peak);
    local_slope = dydz(1:j_search);
    if all(~isfinite(local_slope))
        run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
            run_warn_state, 'CerUPP:OnsetFromTrace:NoFiniteLocalSlope', ...
            'No finite slope samples in onset search interval; returning NaN.');
        det.status = filament_diagnostics_utils_make_status_local('no_finite_local_slope');
        return;
    end
    local_slope(~isfinite(local_slope)) = -Inf;
    [~, j_rel] = max(local_slope);
    if ~isfinite(j_rel)
        run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
            run_warn_state, 'CerUPP:OnsetFromTrace:InvalidOnsetIndex', ...
            'Computed onset index is invalid; returning NaN.');
        det.status = filament_diagnostics_utils_make_status_local('invalid_onset_index');
        return;
    end
    onset_idx_val = max(1, min(nz, j_rel));
    onset_z_val = z_vec(onset_idx_val);
    if ~isfinite(onset_z_val)
        run_warn_state = filament_diagnostics_utils_emit_warn_local( ...
            run_warn_state, 'CerUPP:OnsetFromTrace:InvalidOnsetZ', ...
            'Computed onset z is non-finite; returning NaN.');
        det.status = filament_diagnostics_utils_make_status_local('invalid_onset_z');
        return;
    end

    det.z_onset = onset_z_val;
    det.onset_idx = onset_idx_val;
    det.status = filament_diagnostics_utils_make_status_local('ok');
end

function run_warn_state = filament_diagnostics_utils_emit_warn_local(run_warn_state, canon_id, msg_fmt, varargin)
% Route onset/notch warnings through the owned end-phase ledger when available.

    if nargin < 1 || isempty(run_warn_state)
        run_warn_state = struct();
    elseif ~isstruct(run_warn_state)
        error('CerUPP:InvalidRunWarnState', ...
            'run_warn_state must be a struct or empty ([]); got %s.', class(run_warn_state));
    end
    run_warn_state = run_warn_state_utils.emit_softwarn_each_time_with_phase( ...
        run_warn_state, 'end', canon_id, msg_fmt, varargin{:});
end

function det = filament_diagnostics_utils_finalize_onset_det_local(det, attach_trace, data_trace)
% Attach the original trace only at the single detector completion point.

    if nargin >= 2 && logical(attach_trace)
        det.trace = data_trace;
    end
end

function [status_code, dz_tol] = filament_diagnostics_utils_validate_trace_grid_local(z_vec, trace_vec, min_samples)
% Shared z-grid / trace-shape admissibility gate for onset detectors.

    if nargin < 3 || isempty(min_samples)
        min_samples = 1;
    end
    dz_tol = NaN;
    nz = numel(z_vec);
    if nz < 1
        status_code = 'empty_z';
        return;
    end
    if numel(trace_vec) ~= nz
        status_code = 'length_mismatch';
        return;
    end
    if any(~isfinite(z_vec))
        status_code = 'nonfinite_z';
        return;
    end
    dz_raw = diff(z_vec);
    if ~all(dz_raw > 0)
        status_code = 'nonincreasing_z';
        return;
    end
    z_scale = max(abs(z_vec));
    dz_tol = 1024 * eps(max(z_scale, 1));
    if any(abs(dz_raw) <= dz_tol)
        status_code = 'degenerate_spacing';
        return;
    end
    if nz < min_samples
        status_code = 'too_few_samples';
        return;
    end
    status_code = 'ok';
end



function use_parseval_effective = resolve_parseval_effective_local( ...
    t, delta_t, fluence_use_parseval, parseval_time_grid_ok)
% Resolve the effective Parseval mode from the request and time-grid contract.

    use_parseval_effective = logical(fluence_use_parseval);
    if ~use_parseval_effective
        return;
    end
    if ~isscalar(delta_t) || ~isfinite(delta_t) || (delta_t <= 0)
        error('CerUPP:InvalidFluenceDeltaT', ...
            'delta_t must be finite and >0 when fluence_use_parseval=true.');
    end
    if isempty(parseval_time_grid_ok)
        use_parseval_effective = filament_diagnostics_utils.time_grid_supports_parseval_fluence(t, delta_t);
    else
        use_parseval_effective = logical(parseval_time_grid_ok);
    end
end

function request = normalize_band_diag_request_local(request_in)
% Normalize one-band requests onto the fixed four-flag schema.

    request = band_diag_request_template_local(false);
    if nargin < 1 || isempty(request_in)
        return;
    end
    if (ischar(request_in) && isrow(request_in)) || (isstring(request_in) && isscalar(request_in))
        request = band_diag_request_profile_local(request_in);
        return;
    end
    if ~(isstruct(request_in) && isscalar(request_in))
        error('CerUPP:InvalidBandDiagRequest', ...
            'Band diagnostic request must be a struct or explicit default-profile token when provided.');
    end
    allowed_fields = {'fluence', 'td_oa', 'td_bc', 'td_maxperp', 'default_profile'};
    unknown_field_names = setdiff(fieldnames(request_in).', allowed_fields);
    if ~isempty(unknown_field_names)
        error('CerUPP:InvalidBandDiagRequest', ...
            ['Unknown band diagnostic request field(s): %s. Allowed fields: %s.'], ...
            strjoin(unknown_field_names, ', '), strjoin(allowed_fields, ', '));
    end
    if isfield(request_in, 'default_profile') && ~isempty(request_in.default_profile)
        request = band_diag_request_profile_local(request_in.default_profile);
    end
    if isfield(request_in, 'fluence') && ~isempty(request_in.fluence)
        request.fluence = normalize_band_diag_request_bool_local(request_in.fluence, 'fluence');
    end
    if isfield(request_in, 'td_oa') && ~isempty(request_in.td_oa)
        request.td_oa = normalize_band_diag_request_bool_local(request_in.td_oa, 'td_oa');
    end
    if isfield(request_in, 'td_bc') && ~isempty(request_in.td_bc)
        request.td_bc = normalize_band_diag_request_bool_local(request_in.td_bc, 'td_bc');
    end
    if isfield(request_in, 'td_maxperp') && ~isempty(request_in.td_maxperp)
        request.td_maxperp = normalize_band_diag_request_bool_local(request_in.td_maxperp, 'td_maxperp');
    end
end

function request_stack = normalize_multi_band_diag_request_local(request_in, n_bands)
% Normalize scalar/array/profile band requests while preserving broadcast semantics.

    if ~(isscalar(n_bands) && isnumeric(n_bands) && isreal(n_bands) && ...
            isfinite(n_bands) && (n_bands >= 0) && (fix(n_bands) == n_bands))
        error('CerUPP:InvalidBandDiagRequest', ...
            'n_bands must be a finite nonnegative integer scalar.');
    end
    request_stack = repmat(band_diag_request_template_local(false), 1, n_bands);
    if (n_bands == 0) || (nargin < 1) || isempty(request_in)
        return;
    end
    if (ischar(request_in) && isrow(request_in)) || (isstring(request_in) && isscalar(request_in))
        request_stack = repmat(band_diag_request_profile_local(request_in), 1, n_bands);
        return;
    end
    if ~isstruct(request_in)
        error('CerUPP:InvalidBandDiagRequest', ...
            ['Multi-band diagnostic request must be a struct, struct array, or ', ...
             'explicit default-profile token when provided.']);
    end
    if isscalar(request_in)
        if n_bands == 1
            request_stack = normalize_band_diag_request_local(request_in);
            return;
        end
        allowed_fields = {'fluence', 'td_oa', 'td_bc', 'td_maxperp', 'default_profile', 'broadcast_to_all_bands'};
        unknown_field_names = setdiff(fieldnames(request_in).', allowed_fields);
        if ~isempty(unknown_field_names)
            error('CerUPP:InvalidBandDiagRequest', ...
                ['Unknown band diagnostic request field(s): %s. Allowed fields: %s.'], ...
                strjoin(unknown_field_names, ', '), strjoin(allowed_fields, ', '));
        end
        broadcast_to_all_bands = false;
        if isfield(request_in, 'broadcast_to_all_bands') && ~isempty(request_in.broadcast_to_all_bands)
            broadcast_to_all_bands = normalize_band_diag_request_bool_local( ...
                request_in.broadcast_to_all_bands, 'broadcast_to_all_bands');
        end
        if ~broadcast_to_all_bands
            error('CerUPP:InvalidBandDiagRequest', ...
                ['Scalar multi-band diagnostic requests require either a struct array ', ...
                 'matching n_bands or broadcast_to_all_bands=true.']);
        end
        request_single = request_in;
        if isfield(request_single, 'broadcast_to_all_bands')
            request_single = rmfield(request_single, 'broadcast_to_all_bands');
        end
        request_stack = repmat(normalize_band_diag_request_local(request_single), 1, n_bands);
        return;
    end
    request_in = reshape(request_in, 1, []);
    if numel(request_in) ~= n_bands
        error('CerUPP:InvalidBandDiagRequest', ...
            'Multi-band diagnostic request count (%d) must match number of bands (%d).', ...
            numel(request_in), n_bands);
    end
    for band_idx = 1:n_bands
        request_stack(band_idx) = normalize_band_diag_request_local(request_in(band_idx));
    end
end

function request = band_diag_request_profile_local(profile_in)
% Resolve the named all/none profile for one-band requests.

    profile_key = lower(strtrim(char(string(profile_in))));
    switch profile_key
        case 'none'
            request = band_diag_request_template_local(false);
        case 'all'
            request = band_diag_request_template_local(true);
        otherwise
            error('CerUPP:InvalidBandDiagRequest', ...
                ['Unknown band diagnostic default profile "%s". Use ', ...
                 'all or none.'], ...
                profile_in);
    end
end

function request = band_diag_request_template_local(flag_value)
% Canonical one-band request schema.

    flag_value = logical(flag_value);
    request = struct( ...
        'fluence', flag_value, ...
        'td_oa', flag_value, ...
        'td_bc', flag_value, ...
        'td_maxperp', flag_value);
end

function flag_out = normalize_band_diag_request_bool_local(value_in, field_name)
% Normalize public band-diagnostic booleans using the shared strict {0,1} contract.

    flag_out = struct_utils.normalize_bool_scalar( ...
        value_in, field_name, 'CerUPP:InvalidBandDiagRequest');
end
