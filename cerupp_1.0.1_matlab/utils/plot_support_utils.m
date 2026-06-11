classdef plot_support_utils
%PLOT_SUPPORT_UTILS Shared plot-session, export, and diagnostic helpers.
% Used by plot_utils.m and the Section 6 postprocessing plot families.

    methods (Static)
        function varargout = build_spectral_lambda_axis_ctx(varargin)
        %BUILD_SPECTRAL_LAMBDA_AXIS_CTX Shared spectral wavelength-axis helper.

            lambda_m = plot_utils_require_lambda_axis_window_local(varargin{1});
            c_const = plot_utils_require_positive_real_scalar_local( ...
                varargin{2}, 'c_const', 'CerUPP:Plot:InvalidSpectralLambdaAxisCConst');
            lambda_nm = lambda_m * 1e9;
            [lambda_nm_sorted, idx_lam] = sort(lambda_nm, 'ascend');
            lambda_m_sorted = lambda_m(idx_lam);
            hz_to_nm_factor = (c_const ./ (lambda_m.^2)) * 1e-9;
            radps_to_nm_factor = (2*pi*c_const ./ (lambda_m.^2)) * 1e-9;
            spectral_lambda_ctx = struct( ...
                'lambda_m', lambda_m, ...
                'lambda_nm', lambda_nm, ...
                'idx_lam', idx_lam, ...
                'lambda_m_sorted', lambda_m_sorted, ...
                'lambda_nm_sorted', lambda_nm_sorted, ...
                'hz_to_nm_factor', hz_to_nm_factor, ...
                'hz_to_nm_factor_sorted', hz_to_nm_factor(idx_lam), ...
                'radps_to_nm_factor', radps_to_nm_factor, ...
                'radps_to_nm_factor_sorted', radps_to_nm_factor(idx_lam));
            varargout = {spectral_lambda_ctx};
        end

        function varargout = plot_keldysh_rate_diagnostic(varargin)
        %PLOT_KELDYSH_RATE_DIAGNOSTIC Setup-time Keldysh diagnostic helper.

            [varargout{1:nargout}] = plot_utils_plot_keldysh_rate_diagnostic_impl(varargin{:});
        end

        function [beamcenter_plot_state, run_warn_state] = resolve_beamcenter_plot_state_from_store(cfg, run_warn_state)
        % Resolve the stored beam-center plot state on the output side before Section 6.
        % This helper decides whether the centroid-sampled beam center ever
        % leaves the on-axis sample and emits the companion plot warnings once.

            if nargin < 1 || ~isstruct(cfg)
                error('CerUPP:InvalidBeamcenterPlotStateCfg', ...
                    'resolve_beamcenter_plot_state_from_store requires a struct cfg.');
            end
            if nargin < 2 || ~isstruct(run_warn_state)
                run_warn_state = struct();
            end

            store_z = cfg.store_z(:);
            num_store_planes = numel(store_z);
            store_beamcenter_ix = cfg.store_beamcenter_ix(:);
            store_beamcenter_iy = cfg.store_beamcenter_iy(:);
            store_beamcenter_x = cfg.store_beamcenter_x(:);
            store_beamcenter_y = cfg.store_beamcenter_y(:);
            store_beamcenter_method_code = cfg.store_beamcenter_method_code(:);
            beamcenter_vector_lengths = [ ...
                numel(store_beamcenter_method_code), ...
                numel(store_beamcenter_ix), ...
                numel(store_beamcenter_iy), ...
                numel(store_beamcenter_x), ...
                numel(store_beamcenter_y)];
            if logical(cfg.store_beamcenter_history_flag) && ...
                    any(beamcenter_vector_lengths ~= num_store_planes)
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, 'end', ...
                    'beam_center_store_length_mismatch', ...
                    'CerUPP:BeamCenter:StoreLengthMismatch', ...
                    ['Beam-center plot state is disabled because the stored beam-center companion vectors ', ...
                     'do not match numel(store_z)=%d (num_storage_steps=%d, method=%d, ix=%d, iy=%d, x=%d, y=%d). ', ...
                     'Beam-center companion plots will be skipped for this run instead of failing during end-phase postprocessing.'], ...
                    num_store_planes, double(cfg.num_storage_steps), ...
                    beamcenter_vector_lengths(1), beamcenter_vector_lengths(2), ...
                    beamcenter_vector_lengths(3), beamcenter_vector_lengths(4), ...
                    beamcenter_vector_lengths(5));
                beamcenter_plot_state = struct( ...
                    'history_enabled', logical(cfg.store_beamcenter_history_flag), ...
                    'store_z', store_z, ...
                    'valid_store_mask', false(num_store_planes, 1), ...
                    'method_valid_mask', false(num_store_planes, 1), ...
                    'centroid_unavailable_count', 0, ...
                    'store_ix', store_beamcenter_ix, ...
                    'store_iy', store_beamcenter_iy, ...
                    'store_x', store_beamcenter_x, ...
                    'store_y', store_beamcenter_y, ...
                    'store_method_code', store_beamcenter_method_code, ...
                    'axis_ix', cfg.ix_axis0, ...
                    'axis_iy', cfg.iy_axis0, ...
                    'axis_x', cfg.x_axis0, ...
                    'axis_y', cfg.y_axis0, ...
                    'offaxis_mask', false(num_store_planes, 1), ...
                    'offaxis_any', false, ...
                    'first_offaxis_idx', NaN, ...
                    'first_offaxis_z', NaN, ...
                    'beam_center_offaxis_any', false);
                return;
            end

            valid_store_mask = isfinite(store_z);
            if ~any(valid_store_mask)
                if cfg.store_beamcenter_history_flag
                    run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                        run_warn_state, 'end', ...
                        'beam_center_store_z_unavailable', ...
                        'CerUPP:BeamCenter:StoreZUnavailable', ...
                        ['Beam-center plot state is unavailable because store_z has no finite samples. ', ...
                         'Beam-center companion warnings and off-axis detection are skipped for this run.']);
                end
                beamcenter_plot_state = struct( ...
                    'history_enabled', logical(cfg.store_beamcenter_history_flag), ...
                    'store_z', store_z, ...
                    'valid_store_mask', valid_store_mask, ...
                    'method_valid_mask', false(num_store_planes, 1), ...
                    'centroid_unavailable_count', 0, ...
                    'store_ix', store_beamcenter_ix, ...
                    'store_iy', store_beamcenter_iy, ...
                    'store_x', store_beamcenter_x, ...
                    'store_y', store_beamcenter_y, ...
                    'store_method_code', store_beamcenter_method_code, ...
                    'axis_ix', cfg.ix_axis0, ...
                    'axis_iy', cfg.iy_axis0, ...
                    'axis_x', cfg.x_axis0, ...
                    'axis_y', cfg.y_axis0, ...
                    'offaxis_mask', false(num_store_planes, 1), ...
                    'offaxis_any', false, ...
                    'first_offaxis_idx', NaN, ...
                    'first_offaxis_z', NaN, ...
                    'beam_center_offaxis_any', false);
                return;
            end

            beam_center_offaxis_mask = false(num_store_planes, 1);
            beam_center_offaxis_any = false;
            beamcenter_method_valid_mask = false(num_store_planes, 1);
            beamcenter_unavailable_count = 0;
            first_off_idx = NaN;
            if cfg.store_beamcenter_history_flag && ...
                    ~isempty(store_beamcenter_ix) && ~isempty(store_beamcenter_iy)
                beamcenter_method_valid_mask = valid_store_mask & ...
                    (store_beamcenter_method_code == 1) & ...
                    isfinite(store_beamcenter_ix) & isfinite(store_beamcenter_iy);
                beamcenter_unavailable_count = nnz(valid_store_mask) - nnz(beamcenter_method_valid_mask);
                if beamcenter_unavailable_count > 0
                    run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                        run_warn_state, 'end', ...
                        'beam_center_centroid_unavailable', ...
                        'CerUPP:BeamCenter:CentroidUnavailable', ...
                        ['Beam-center centroid sampling was unavailable on %d/%d stored planes. ', ...
                         'Beam-center-derived diagnostics retain NaN gaps on those planes instead of using argmax or axis fallback.'], ...
                        beamcenter_unavailable_count, nnz(valid_store_mask));
                end
                beam_center_offaxis_mask(beamcenter_method_valid_mask) = ...
                    (store_beamcenter_ix(beamcenter_method_valid_mask) ~= cfg.ix_axis0) | ...
                    (store_beamcenter_iy(beamcenter_method_valid_mask) ~= cfg.iy_axis0);
                beam_center_offaxis_any = any(beam_center_offaxis_mask);
                if beam_center_offaxis_any
                    first_off_idx = find(beam_center_offaxis_mask, 1, 'first');
                    run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                        run_warn_state, 'end', ...
                        'beam_center_off_axis_detected', ...
                        'CerUPP:BeamCenter:OffAxisDetected', ...
                        ['Beam-center centroid sample left the on-axis sample point at z=%.6g m ', ...
                         '(axis x=%.3e m, y=%.3e m; centroid-sampled beam-center x=%.3e m, y=%.3e m). ', ...
                         'Companion beam-center-vs-z traces will be generated alongside on-axis plots.'], ...
                        store_z(first_off_idx), cfg.x_axis0, cfg.y_axis0, ...
                        store_beamcenter_x(first_off_idx), store_beamcenter_y(first_off_idx));
                    run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                        run_warn_state, 'end', ...
                        'fwhm_proxy_off_axis_detected', ...
                        'CerUPP:BeamCenter:FwhmProxyOffAxisDetected', ...
                        ['From z=%.6g m onward, stored FWHM diameter-vs-z outputs are beam-center-tracked ', ...
                         'cut-based proxies rather than universal 2D widths.'], ...
                        store_z(first_off_idx));
                end
            end

            beamcenter_plot_state = struct( ...
                'history_enabled', logical(cfg.store_beamcenter_history_flag), ...
                'store_z', store_z, ...
                'valid_store_mask', valid_store_mask, ...
                'method_valid_mask', beamcenter_method_valid_mask, ...
                'centroid_unavailable_count', beamcenter_unavailable_count, ...
                'store_ix', store_beamcenter_ix, ...
                'store_iy', store_beamcenter_iy, ...
                'store_x', store_beamcenter_x, ...
                'store_y', store_beamcenter_y, ...
                'store_method_code', store_beamcenter_method_code, ...
                'axis_ix', cfg.ix_axis0, ...
                'axis_iy', cfg.iy_axis0, ...
                'axis_x', cfg.x_axis0, ...
                'axis_y', cfg.y_axis0, ...
                'offaxis_mask', beam_center_offaxis_mask, ...
                'offaxis_any', beam_center_offaxis_any, ...
                'first_offaxis_idx', first_off_idx, ...
                'first_offaxis_z', NaN, ...
                'beam_center_offaxis_any', beam_center_offaxis_any);
            if isfinite(first_off_idx) && (first_off_idx >= 1) && ...
                    (first_off_idx <= num_store_planes)
                beamcenter_plot_state.first_offaxis_z = store_z(first_off_idx);
            end
        end
    end

    methods (Static, Hidden)
        function plot_settings = normalize_public_plot_settings(plot_settings_in)
        % Normalize the canonical public plot-settings struct to one explicit shape.
        % Public plot settings keep the ordinary visual/export controls here.
        % Phase-routing and failure-routing options are passed separately.

            if nargin < 1 || isempty(plot_settings_in)
                plot_settings_in = struct();
            end
            if ~(isstruct(plot_settings_in) && isscalar(plot_settings_in))
                error('plot_utils:InvalidPublicPlotSettings', ...
                    'The public plot settings input must be a scalar struct.');
            end
            if isfield(plot_settings_in, 'session') && ...
                    isstruct(plot_settings_in.session) && ...
                    isscalar(plot_settings_in.session) && ...
                    ~isfield(plot_settings_in, 'outdir') && ...
                    ~isfield(plot_settings_in, 'warn') && ...
                    ~isfield(plot_settings_in, 'visible') && ...
                    ~isfield(plot_settings_in, 'save_outputs_as_fig') && ...
                    ~isfield(plot_settings_in, 'save_outputs_as_png')
                plot_settings_in = plot_settings_in.session;
            end

            outdir = struct_utils.opt_struct_field(plot_settings_in, 'outdir', 'output_plots');
            if isstring(outdir) && isscalar(outdir)
                outdir = char(outdir);
            end
            outdir = strtrim(char(outdir));
            warn_flag = struct_utils.normalize_bool_scalar( ...
                struct_utils.opt_struct_field(plot_settings_in, 'warn', true), ...
                'plot_settings.warn', 'plot_utils:InvalidPublicPlotSettingsWarn');

            visible_in = struct_utils.opt_struct_field(plot_settings_in, 'visible', false);
            visible_flag = struct_utils.normalize_bool_scalar( ...
                visible_in, 'plot_settings.visible', 'plot_utils:InvalidPublicPlotSettingsVisible');

            save_outputs_as_fig = struct_utils.normalize_bool_scalar( ...
                struct_utils.opt_struct_field(plot_settings_in, 'save_outputs_as_fig', false), ...
                'plot_settings.save_outputs_as_fig', 'plot_utils:InvalidPublicPlotSettingsSaveFig');
            save_outputs_as_png = struct_utils.normalize_bool_scalar( ...
                struct_utils.opt_struct_field(plot_settings_in, 'save_outputs_as_png', false), ...
                'plot_settings.save_outputs_as_png', 'plot_utils:InvalidPublicPlotSettingsSavePng');

            close_figure = [];
            if isfield(plot_settings_in, 'close_figure') && ~isempty(plot_settings_in.close_figure)
                close_figure = struct_utils.normalize_bool_scalar( ...
                    plot_settings_in.close_figure, 'plot_settings.close_figure', ...
                    'plot_utils:InvalidPublicPlotSettingsCloseFigure');
            end

            plot_settings = struct( ...
                'outdir', outdir, ...
                'warn', warn_flag, ...
                'visible', visible_flag, ...
                'save_outputs_as_fig', save_outputs_as_fig, ...
                'save_outputs_as_png', save_outputs_as_png);
            if ~isempty(close_figure)
                plot_settings.close_figure = close_figure;
            end
        end

        function varargout = begin_figure_session(varargin)
        %BEGIN_FIGURE_SESSION Internal custom-figure session entry helper.

            outdir = varargin{1};
            fig_name_base = varargin{2};
            run_warn_state = varargin{3};
            plot_policy_in = varargin{4};
            create_figure = false;
            phase_tag = run_warn_state_utils.phase_end();
            record_failure_tag = 'png_export';
            custom_args = varargin(5:end);
            [custom_args, found_create_figure, create_figure_value] = plot_utils_consume_named_option_local( ...
                custom_args, {'create_figure'}, @plot_support_utils.parse_bool_like);
            if found_create_figure
                create_figure = create_figure_value;
            end
            if ~(isstruct(plot_policy_in) && isscalar(plot_policy_in))
                error('CerUPP:Plot:InvalidFigureSessionPlotPolicy', ...
                    'begin_figure_session requires one scalar plot settings struct.');
            end
            [custom_args, found_phase_tag, phase_tag_value] = plot_utils_consume_named_option_local( ...
                custom_args, {'phase_tag'}, @plot_support_utils.parse_char_scalar);
            if found_phase_tag
                phase_tag = run_warn_state_utils.canonical_phase_name(phase_tag_value);
            end
            [custom_args, found_record_failure_tag, record_failure_tag_value] = plot_utils_consume_named_option_local( ...
                custom_args, {'record_failure_tag'}, @plot_support_utils.parse_char_scalar);
            if found_record_failure_tag
                record_failure_tag = char(string(record_failure_tag_value));
            end
            show_plots_flag = struct_utils.opt_struct_field(plot_policy_in, 'visible', false);
            save_outputs_as_fig = struct_utils.opt_struct_field(plot_policy_in, 'save_outputs_as_fig', false);
            save_outputs_as_png = struct_utils.opt_struct_field(plot_policy_in, 'save_outputs_as_png', false);
            [session, run_warn_state, ok] = plot_utils_begin_diagnostic_session_local( ...
                outdir, fig_name_base, run_warn_state, show_plots_flag, ...
                '', '', '', save_outputs_as_fig, save_outputs_as_png);
            fig_handle = [];
            if ok
                session.phase_tag = run_warn_state_utils.canonical_phase_name(phase_tag);
                session.record_failure_tag = char(string(record_failure_tag));
                if ~isempty(custom_args)
                    error('CerUPP:PlotArgs:UnknownFigureSessionOption', ...
                        'Unknown BEGIN_FIGURE_SESSION option(s): %s', ...
                        plot_utils_named_option_summary_local(custom_args));
                end
                if create_figure
                    visible_mode = 'off';
                    if session.visible_now
                        visible_mode = 'on';
                    end
                    fig_handle = figure('Color', 'w', 'Visible', visible_mode);
                end
            end
            varargout = {fig_handle, session, run_warn_state, ok};
        end

        function varargout = finalize_figure_session(varargin)
        %FINALIZE_FIGURE_SESSION Internal custom-figure session finalizer helper.

            fig_handle = varargin{1};
            session = varargin{2};
            run_warn_state = varargin{3};
            savefig_warn_id = 'CerUPP:Plot:SaveFigFailed';
            savefig_warn_fmt = 'Failed to save FIG "%s": %s';
            png_warn_key = 'png_export_failed';
            png_warn_id = 'CerUPP:Plot:ExportGraphicsFailed';
            finalize_args = varargin(4:end);
            [finalize_args, found_savefig_warn_id, savefig_warn_id_value] = plot_utils_consume_named_option_local( ...
                finalize_args, {'savefig_warn_id'}, @plot_support_utils.parse_char_scalar);
            if found_savefig_warn_id
                savefig_warn_id = savefig_warn_id_value;
            end
            [finalize_args, found_savefig_warn_fmt, savefig_warn_fmt_value] = plot_utils_consume_named_option_local( ...
                finalize_args, {'savefig_warn_fmt'}, @plot_support_utils.parse_char_scalar);
            if found_savefig_warn_fmt
                savefig_warn_fmt = savefig_warn_fmt_value;
            end
            [finalize_args, found_png_warn_key, png_warn_key_value] = plot_utils_consume_named_option_local( ...
                finalize_args, {'png_warn_key'}, @plot_support_utils.parse_char_scalar);
            if found_png_warn_key
                png_warn_key = png_warn_key_value;
            end
            [finalize_args, found_png_warn_id, png_warn_id_value] = plot_utils_consume_named_option_local( ...
                finalize_args, {'png_warn_id'}, @plot_support_utils.parse_char_scalar);
            if found_png_warn_id
                png_warn_id = png_warn_id_value;
            end
            if ~isempty(finalize_args)
                error('CerUPP:PlotArgs:UnknownFigureFinalizeOption', ...
                    'Unknown FINALIZE_FIGURE_SESSION option(s): %s', ...
                    plot_utils_named_option_summary_local(finalize_args));
            end
            run_warn_state = plot_utils_finalize_diagnostic_figure_local( ...
                fig_handle, session, run_warn_state, ...
                savefig_warn_id, savefig_warn_fmt, png_warn_key, png_warn_id);
            varargout = {run_warn_state};
        end

        function varargout = mark_nonfinite_for_diagnostics(varargin)
        %MARK_NONFINITE_FOR_DIAGNOSTICS Diagnostic sanitation helper.

            x_in = varargin{1};
            label = varargin{2};
            naninfo = struct('label', {}, 'n_nan', {}, 'n_cap', {}, 'cap_hi', {});
            if numel(varargin) >= 3 && ~isempty(varargin{3})
                naninfo = varargin{3};
            end
            cap_hi = 1e120;
            if numel(varargin) >= 4 && ~isempty(varargin{4})
                cap_hi = varargin{4};
            end
            treat_nan_as_blowup = false;
            if numel(varargin) >= 5 && ~isempty(varargin{5})
                treat_nan_as_blowup = varargin{5};
            end
            run_warn_state = struct();
            if numel(varargin) >= 6 && ~isempty(varargin{6})
                run_warn_state = varargin{6};
            end
            phase_tag = run_warn_state_utils.phase_end();
            if numel(varargin) >= 7 && ~isempty(varargin{7})
                phase_tag = varargin{7};
            end
            opts_nf = struct( ...
                'count_only', true, ...
                'warn', true, ...
                'warn_id', 'CerUPP:Diagnostics:NonFiniteDetected', ...
                'cap_value', cap_hi, ...
                'treat_nan_as_blowup', logical(treat_nan_as_blowup), ...
                'naninfo', naninfo, ...
                'run_warn_state', run_warn_state, ...
                'phase_tag', phase_tag);
            [x_out, naninfo, ~, run_warn_state] = plot_utils.sanitize_nonfinite_diag(real(x_in), label, opts_nf);
            bad_count = nnz(~isfinite(x_out));
            varargout = {x_out, bad_count, naninfo, run_warn_state};
        end

        function [x_out, info, run_warn_state] = clamp_nonnegative_diagnostic_leakage( ...
                x_in, label, run_warn_state, phase_tag, warn_key, warn_id)
        % Clamp derived diagnostic leakage onto the nonnegative-real surface with one owned warning.

            if nargin < 3 || ~isstruct(run_warn_state)
                run_warn_state = struct();
            end
            if nargin < 4 || isempty(phase_tag)
                phase_tag = run_warn_state_utils.phase_end();
            end
            if nargin < 5 || isempty(warn_key)
                warn_key = 'diagnostic_nonnegative_leakage_clamped';
            end
            if nargin < 6 || isempty(warn_id)
                warn_id = 'CerUPP:Diagnostics:NonnegativeLeakageClamped';
            end

            x_out = x_in;
            info = struct( ...
                'had_issue', false, ...
                'n_negative', 0, ...
                'n_complex', 0, ...
                'min_real', NaN, ...
                'max_abs_imag', NaN, ...
                'tol', NaN, ...
                'beyond_tol', false);
            if isempty(x_out)
                return;
            end

            finite_mask = isfinite(x_out);
            if ~any(finite_mask(:))
                return;
            end

            finite_vals = x_out(finite_mask);
            finite_real = real(finite_vals);
            finite_imag = imag(finite_vals);
            max_abs_real = max(abs(finite_real(:)));
            tol = struct_utils.cerupp_numeric_threshold('rel_tol_tight') * max(max_abs_real, 1);
            max_abs_imag = max(abs(finite_imag(:)));
            min_real = min(finite_real(:));

            negative_mask = false(size(x_out));
            negative_mask(finite_mask) = (finite_real < 0);
            complex_mask = false(size(x_out));
            complex_mask(finite_mask) = (abs(finite_imag) > 0);
            n_negative = nnz(negative_mask);
            n_complex = nnz(complex_mask);
            if ~(n_negative > 0 || n_complex > 0)
                return;
            end

            x_out = real(x_out);
            x_out(negative_mask & finite_mask) = 0;
            beyond_tol = (min_real < -tol) || (max_abs_imag > tol);
            severity_label = 'within leakage tolerance';
            if beyond_tol
                severity_label = 'beyond leakage tolerance';
            end
            run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                run_warn_state, phase_tag, warn_key, warn_id, ...
                ['%s: clamped derived diagnostic leakage onto the nonnegative-real surface; ', ...
                 'n_negative=%d, n_complex=%d, min(real)=%.3e, max|imag|=%.3e, tol=%.3e (%s).'], ...
                label, n_negative, n_complex, min_real, max_abs_imag, tol, severity_label);
            info = struct( ...
                'had_issue', true, ...
                'n_negative', n_negative, ...
                'n_complex', n_complex, ...
                'min_real', min_real, ...
                'max_abs_imag', max_abs_imag, ...
                'tol', tol, ...
                'beyond_tol', beyond_tol);
        end

        function varargout = make_log10_nonnegative_for_plot(varargin)
        %MAKE_LOG10_NONNEGATIVE_FOR_PLOT Display-only log10 sanitation helper.

            x_in = varargin{1};
            eps_safe = varargin{2};
            quantity_label = 'quantity';
            if numel(varargin) >= 3 && ~isempty(varargin{3})
                quantity_label = varargin{3};
            end
            run_warn_state = struct();
            if numel(varargin) >= 4 && isstruct(varargin{4})
                run_warn_state = varargin{4};
            end
            phase_tag = run_warn_state_utils.phase_end();
            if numel(varargin) >= 5 && ~isempty(varargin{5})
                phase_tag = varargin{5};
            end
            opts_nf = struct( ...
                'warn', true, ...
                'warn_id', 'CerUPP:Plot:NonFiniteCapped', ...
                'cap_value', 1e120, ...
                'treat_nan_as_blowup', false, ...
                'replace_nonfinite_with_nan', true, ...
                'run_warn_state', run_warn_state, ...
                'phase_tag', phase_tag);
            [x_plot, ~, ~, run_warn_state] = plot_utils.sanitize_nonfinite_diag(real(x_in), ...
                ['make_log10_nonnegative_for_plot:' char(quantity_label)], opts_nf);
            neg_mask = isfinite(x_plot) & (x_plot < 0);
            if any(neg_mask(:))
                run_warn_state = run_warn_state_utils.emit_softwarn_each_time_with_phase( ...
                    run_warn_state, phase_tag, 'CerUPP:PlotLog10NegativeMasked', ...
                    'Masking %d negative samples before log10 for %s.', ...
                    nnz(neg_mask), quantity_label);
                x_plot(neg_mask) = NaN;
            end
            x_log10 = log10(x_plot + eps_safe);
            varargout = {x_log10, x_plot, run_warn_state};
        end

        function varargout = emit_isosurface_volume(varargin)
        %EMIT_ISOSURFACE_VOLUME Shared isosurface sanitation/emission helper.

            run_warn_state = varargin{1};
            naninfo = varargin{2};
            x_mm = varargin{3};
            y_mm = varargin{4};
            z_mm = varargin{5};
            volume_data = varargin{6};
            cut_frac = varargin{7};
            title_fmt = varargin{8};
            stem = varargin{9};
            invalid_max_msg = varargin{10};
            helper_skip_msg = varargin{11};
            sanitized_skip_fmt = varargin{12};
            plot_policy_in = varargin{13};
            plot_nv_pairs = {};
            title_fmt_args = varargin(14:end);
            if ~isempty(title_fmt_args) && iscell(title_fmt_args{1})
                plot_nv_pairs = title_fmt_args{1};
                title_fmt_args = title_fmt_args(2:end);
            end
            sanitize_opts = struct( ...
                'warn', false, ...
                'replace_nonfinite_with_nan', true, ...
                'cap_value', 1e120, ...
                'treat_nan_as_blowup', false);
            [volume_sanitized, ~, ~, ~] = plot_utils.sanitize_nonfinite_diag( ...
                volume_data, 'emit_isosurface_volume:volume_data', sanitize_opts);
            volume_max = max(volume_sanitized(:), [], 'omitnan');
            if ~isfinite(volume_max) || (volume_max <= 0)
                run_warn_state = run_warn_state_utils.record_warning_phase_event( ...
                    run_warn_state, run_warn_state_utils.phase_end(), ...
                    'CerUPP:Plot:IsosurfaceSkippedInvalidMax', invalid_max_msg);
                varargout = {run_warn_state, naninfo};
                return;
            end
            volume_sz = size(volume_data);
            if numel(volume_sz) < 3
                volume_sz(3) = 1;
                volume_data = reshape(volume_data, volume_sz);
            end
            if (numel(volume_sz) ~= 3) || ...
                    (volume_sz(1) ~= numel(x_mm)) || ...
                    (volume_sz(2) ~= numel(y_mm)) || ...
                    (volume_sz(3) ~= numel(z_mm))
                run_warn_state = run_warn_state_utils.record_warning_phase_event( ...
                    run_warn_state, run_warn_state_utils.phase_end(), ...
                    'CerUPP:Plot:IsosurfaceSkippedSizeMismatch', ...
                    sprintf(['Isosurface plot skipped because volume_data size [%d %d %d] did not match ', ...
                             '[numel(x) numel(y) numel(z)] = [%d %d %d].'], ...
                            volume_sz(1), volume_sz(2), volume_sz(3), ...
                            numel(x_mm), numel(y_mm), numel(z_mm)));
                varargout = {run_warn_state, naninfo};
                return;
            end

            cut_position = cut_frac * volume_max;
            try
                [iso_ok, iso_naninfo, iso_info_nf, run_warn_state] = plot_utils.make_isosurface_plot( ...
                    x_mm, y_mm, z_mm, volume_data, cut_position, ...
                    sprintf(title_fmt, cut_position, 100 * cut_frac, title_fmt_args{:}), ...
                    'x [mm]', 'y [mm]', 'z [mm]', stem, ...
                    plot_policy_in, ...
                    'run_warn_state', run_warn_state, plot_nv_pairs{:});
            catch me
                if strcmp(me.identifier, 'make_isosurface_plot:SizeMismatch')
                    run_warn_state = run_warn_state_utils.record_warning_phase_event( ...
                        run_warn_state, run_warn_state_utils.phase_end(), ...
                        'CerUPP:Plot:IsosurfaceSkippedSizeMismatch', ...
                        sprintf('Isosurface plot skipped after helper size check failed: %s', me.message));
                    varargout = {run_warn_state, naninfo};
                    return;
                end
                rethrow(me);
            end
            if ~isempty(iso_naninfo)
                naninfo = [naninfo, iso_naninfo];
            end
            if ~iso_ok
                iso_skip_msg = helper_skip_msg;
                if isstruct(iso_info_nf) && isfield(iso_info_nf, 'had_issue') && logical(iso_info_nf.had_issue)
                    iso_skip_msg = sprintf(sanitized_skip_fmt, ...
                        double(iso_info_nf.n_nan), double(iso_info_nf.n_cap));
                end
                run_warn_state = run_warn_state_utils.record_warning_phase_event( ...
                    run_warn_state, run_warn_state_utils.phase_end(), ...
                    'CerUPP:Plot:IsosurfaceSkipped', iso_skip_msg);
            end
            varargout = {run_warn_state, naninfo};
        end

        function varargout = close_figure_if_valid(varargin)
        %CLOSE_FIGURE_IF_VALID Valid-handle close helper.

            plot_utils_close_figure_if_needed_local(varargin{1}, true);
            varargout = {};
        end

        function txt_out = sanitize_text_for_none_interpreter(txt_in)
        %SANITIZE_TEXT_FOR_NONE_INTERPRETER Normalize TeX-like markup for Interpreter='none'.

            if isstring(txt_in)
                if isscalar(txt_in)
                    txt_in = char(txt_in);
                else
                    txt_out = cell(size(txt_in));
                    for ii = 1:numel(txt_in)
                        txt_out{ii} = plot_support_utils.sanitize_text_for_none_interpreter(txt_in(ii));
                    end
                    return;
                end
            end
            if iscell(txt_in)
                txt_out = cell(size(txt_in));
                for ii = 1:numel(txt_in)
                    txt_out{ii} = plot_support_utils.sanitize_text_for_none_interpreter(txt_in{ii});
                end
                return;
            end
            if ~ischar(txt_in)
                txt_out = txt_in;
                return;
            end

            txt_out = txt_in;
            replacements = { ...
                '\approx', '~'; ...
                '\int', 'int'; ...
                '\omega', 'omega'; ...
                '\Omega', 'Omega'; ...
                '\rho', 'rho'; ...
                '\eta', 'eta'; ...
                '\phi', 'phi'; ...
                '\theta', 'theta'; ...
                '\Delta', 'Delta'; ...
                '\delta', 'delta'; ...
                '\lambda', 'lambda'; ...
                '\mu', 'mu'; ...
                '\nu', 'nu'; ...
                '\sigma', 'sigma'; ...
                '\alpha', 'alpha'; ...
                '\beta', 'beta'; ...
                '\gamma', 'gamma'; ...
                '\kappa', 'kappa'; ...
                '\cdot', '*'; ...
                '\times', 'x'; ...
                '\pm', '+/-'; ...
                '\leq', '<='; ...
                '\geq', '>='; ...
                '\left', ''; ...
                '\right', ''};
            for rr = 1:size(replacements, 1)
                txt_out = strrep(txt_out, replacements{rr, 1}, replacements{rr, 2});
            end

            txt_out = regexprep(txt_out, '_\\{([^}]*)\\}', '_$1');
            txt_out = regexprep(txt_out, '\\^\\{([^}]*)\\}', '^$1');
            txt_out = strrep(txt_out, '\\_', '_');
            txt_out = strrep(txt_out, '\\^', '^');
            txt_out = strrep(txt_out, '\\{', '{');
            txt_out = strrep(txt_out, '\\}', '}');
            txt_out = strrep(txt_out, char(92), '');
            txt_out = strrep(txt_out, '{', '');
            txt_out = strrep(txt_out, '}', '');
            txt_out = strrep(txt_out, '$', '');
            txt_out = strtrim(regexprep(txt_out, '\\s+', ' '));
        end

        function detail_out = compact_detail_text(detail_in, max_chars)
        %COMPACT_DETAIL_TEXT Compact detail text for warning/error messaging.

            if nargin < 2 || isempty(max_chars) || ~isfinite(max_chars) || (max_chars < 32)
                max_chars = 240;
            end
            if nargin < 1 || isempty(detail_in)
                detail_out = 'n/a';
                return;
            end
            if ischar(detail_in)
                detail_out = detail_in;
            elseif isstring(detail_in)
                detail_out = strjoin(cellstr(detail_in(:).'), ' ');
            else
                try
                    detail_out = evalc('disp(detail_in)');
                catch
                    detail_out = sprintf('[%s detail omitted]', class(detail_in));
                end
            end
            detail_out = strtrim(regexprep(detail_out, '\\s+', ' '));
            if isempty(detail_out)
                detail_out = 'n/a';
                return;
            end
            if numel(detail_out) > max_chars
                detail_out = [detail_out(1:max_chars) ' ...<truncated>'];
            end
        end
    end

    methods (Static, Hidden)
        function [session, parsed_opts] = begin_main_plot( ...
                save_name, save_outputs_as_fig, save_outputs_as_png, option_specs, varargin)
        %BEGIN_MAIN_PLOT Shared main-plot session/option preamble.

            session = plot_utils_init_session_local( ...
                save_name, save_outputs_as_fig, save_outputs_as_png, varargin{:});
            [plot_args, do_warn, parsed_opts] = plot_utils_normalize_option_bundle_with_warn_local( ...
                session.plot_args, option_specs);
            session.plot_args = plot_args;
            session.do_warn = do_warn;
        end

        function [plot_args, run_warn_state, phase_tag, record_failure_tag] = ...
                consume_export_state_options(plot_args, default_record_failure_tag)
        %CONSUME_EXPORT_STATE_OPTIONS Strip hidden export-state options.

            if nargin < 1 || isempty(plot_args)
                plot_args = {};
            end
            if nargin < 2 || isempty(default_record_failure_tag)
                default_record_failure_tag = 'png_export';
            end
            run_warn_state = struct();
            phase_tag = run_warn_state_utils.phase_end();
            record_failure_tag = char(string(default_record_failure_tag));
            [plot_args, found_run_warn_state, run_warn_state_value] = plot_utils_consume_named_option_local( ...
                plot_args, {'run_warn_state'}, @plot_utils_parse_struct_scalar_local);
            if found_run_warn_state
                run_warn_state = run_warn_state_value;
            end
            [plot_args, found_phase_tag, phase_tag_value] = plot_utils_consume_named_option_local( ...
                plot_args, {'phase_tag'}, @plot_support_utils.parse_char_scalar);
            if found_phase_tag
                phase_tag = phase_tag_value;
            end
            [plot_args, found_record_failure_tag, record_failure_tag_value] = plot_utils_consume_named_option_local( ...
                plot_args, {'record_failure_tag'}, @plot_support_utils.parse_char_scalar);
            if found_record_failure_tag
                record_failure_tag = record_failure_tag_value;
            end
            run_warn_state = struct_utils.ensure_warned_keys_map(run_warn_state);
            phase_tag = run_warn_state_utils.canonical_phase_name(phase_tag);
        end

        function [ok_parse, value_out] = parse_bool_like(value_in)
        %PARSE_BOOL_LIKE Shared strict plot-bool parser.

            ok_parse = false;
            value_out = [];
            try
                value_out = struct_utils.normalize_bool_scalar( ...
                    value_in, 'plot boolean option', 'plot_utils:InvalidBoolLikeValue');
                ok_parse = true;
            catch
                ok_parse = false;
                value_out = [];
            end
        end

        function [ok_parse, value_out] = parse_positive_integer(value_in)
        %PARSE_POSITIVE_INTEGER Shared positive-integer plot parser.

            ok_parse = false;
            value_out = [];
            if isnumeric(value_in) && isscalar(value_in) && isfinite(value_in) && ...
                    (value_in > 0) && (round(double(value_in)) == double(value_in))
                value_out = double(value_in);
                ok_parse = true;
            end
        end

        function [ok_parse, value_out] = parse_char_scalar(value_in)
        %PARSE_CHAR_SCALAR Shared char/string scalar parser.

            ok_parse = false;
            value_out = [];
            if ischar(value_in) || (isstring(value_in) && isscalar(value_in))
                value_out = char(value_in);
                ok_parse = true;
            end
        end

        function [ok_parse, value_out] = parse_surface_shading_mode(value_in)
        %PARSE_SURFACE_SHADING_MODE Shared surface shading parser.

            ok_parse = false;
            value_out = [];
            if isstring(value_in) && isscalar(value_in)
                value_in = char(value_in);
            end
            if ~ischar(value_in)
                return;
            end
            value_norm = strtrim(lower(value_in));
            if any(strcmp(value_norm, {'interp', 'interpolated'}))
                value_out = 'interp';
                ok_parse = true;
            elseif strcmp(value_norm, 'flat')
                value_out = 'flat';
                ok_parse = true;
            elseif strcmp(value_norm, 'faceted')
                value_out = 'faceted';
                ok_parse = true;
            end
        end

        function [ok_parse, value_out] = parse_downsample_mode(value_in)
        %PARSE_DOWNSAMPLE_MODE Shared scatter downsampling parser.

            ok_parse = false;
            value_out = [];
            if isstring(value_in) && isscalar(value_in)
                value_in = char(value_in);
            end
            if ischar(value_in)
                value_norm = strtrim(lower(value_in));
                if strcmp(value_norm, 'uniform')
                    value_out = 'uniform';
                    ok_parse = true;
                elseif strcmp(value_norm, 'value_ranked')
                    value_out = 'value_ranked';
                    ok_parse = true;
                end
            end
        end

        function [ok_parse, value_out] = parse_multiline_specs_option(value_in)
        %PARSE_MULTILINE_SPECS_OPTION Shared multiline spec parser.

            [specs_tmp, apply_all_tmp, ok_specs] = normalize_multiline_specs_local(value_in);
            if ~ok_specs
                error('plot_utils:InvalidMultiLineSpecsOption', ...
                    ['multi_line_specs/series_line_specs must be a char row, scalar string, ', ...
                     'string array, char matrix, or cell array of row-char/scalar-string ', ...
                     'MATLAB line-spec tokens.']);
            end
            ok_parse = ok_specs;
            value_out = [];
            if ok_specs
                value_out = struct('specs', {specs_tmp}, 'apply_all', apply_all_tmp);
            end
        end

        function tf = optional_positional_arg_is_empty(arg_in)
        %OPTIONAL_POSITIONAL_ARG_IS_EMPTY Shared empty-placeholder detector.

            if isempty(arg_in)
                tf = true;
                return;
            end
            if ischar(arg_in)
                tf = isempty(strtrim(arg_in));
                return;
            end
            if isstring(arg_in) && isscalar(arg_in)
                tf = strlength(arg_in) == 0;
                return;
            end
            tf = false;
        end

        function [fig_handle, ax_handle] = open_figure(visible_now, hold_on_flag)
        %OPEN_FIGURE Shared figure-construction helper.

            if nargin < 2
                error('plot_utils:MissingHoldOnFlag', ...
                    'plot_support_utils.open_figure requires an explicit hold_on_flag.');
            end
            if visible_now
                fig_visible_mode = 'on';
            else
                fig_visible_mode = 'off';
            end
            fig_handle = figure('Visible', fig_visible_mode);
            ax_handle = axes('Parent', fig_handle);
            if hold_on_flag
                hold(ax_handle, 'on');
            end
        end

        function run_warn_state = finalize_plot_success(fig_handle, session, run_warn_state)
        %FINALIZE_PLOT_SUCCESS Shared plot save/close lifecycle helper.

            if nargin < 3 || isempty(run_warn_state) || ~isstruct(run_warn_state)
                run_warn_state = struct();
            end
            if session.do_save
                run_warn_state = plot_utils_save_figure_local(fig_handle, session, run_warn_state);
            end
            plot_support_utils.finalize_plot_close(fig_handle, session);
        end

        function finalize_plot_close(fig_handle, session)
        %FINALIZE_PLOT_CLOSE Shared plot close helper.

            plot_utils_close_figure_if_needed_local(fig_handle, session.close_figure_now);
        end
    end
end

function run_warn_state = plot_utils_plot_keldysh_rate_diagnostic_impl( ...
    i_lookup_wm2, w_lookup_sinv, k_power_vec, sigma_k_vec, kdyn, ...
    rho_nt_keldysh_norm_m3, rho_nt_m3, plot_policy_in, run_warn_state, varargin)
% Create the volumetric Keldysh OFI diagnostic plot for the current CerUPP
% W_site(I) law shown on a volumetric display axis.
% Best-effort applies only after input validation; malformed caller inputs still error.
% Style target: one log-log panel with the volumetric display of the live
% Keldysh W_site(I) curve and any configured static-MPI comparison branch
% on the same axes.

    if nargin < 8 || isempty(plot_policy_in)
        plot_policy_in = struct();
    elseif ~(isstruct(plot_policy_in) && isscalar(plot_policy_in))
        error('plot_utils:InvalidKeldyshDiagPlotPolicy', ...
            'Keldysh diagnostic plot policy must be a scalar struct.');
    end
    if nargin < 9 || ~isstruct(run_warn_state)
        run_warn_state = struct();
    end
    phase_tag = run_warn_state_utils.phase_end();
    [varargin, found_phase_tag, phase_tag_value] = plot_utils_consume_named_option_local( ...
        varargin, {'phase_tag'}, @plot_support_utils.parse_char_scalar);
    if found_phase_tag
        phase_tag = run_warn_state_utils.canonical_phase_name(phase_tag_value);
    end
    outdir = struct_utils.opt_struct_field(plot_policy_in, 'outdir', '');
    save_outputs_as_fig = struct_utils.opt_struct_field( ...
        plot_policy_in, 'save_outputs_as_fig', false);
    save_outputs_as_png = struct_utils.opt_struct_field( ...
        plot_policy_in, 'save_outputs_as_png', false);
    show_plots_flag = struct_utils.opt_struct_field(plot_policy_in, 'visible', false);
    fig_name_base = char(string(struct_utils.opt_struct_field( ...
        plot_policy_in, 'fig_name_base', 'keldysh_ofi_rate_diagnostic')));
    emit_fixed_window_debug = logical(struct_utils.opt_struct_field( ...
        plot_policy_in, 'emit_fixed_window_debug', true));
    display_i_min_wm2 = double(struct_utils.opt_struct_field( ...
        plot_policy_in, 'display_i_min_wm2', NaN));
    display_i_max_wm2 = double(struct_utils.opt_struct_field( ...
        plot_policy_in, 'display_i_max_wm2', NaN));
    display_range_label = char(string(struct_utils.opt_struct_field( ...
        plot_policy_in, 'display_range_label', 'full evaluated intensity range')));
    show_clamp_markers = logical(struct_utils.opt_struct_field( ...
        plot_policy_in, 'show_clamp_markers', true));
    [session, run_warn_state, ok_session] = plot_utils_begin_diagnostic_session_local( ...
        outdir, fig_name_base, run_warn_state, show_plots_flag, ...
        'keldysh_diag_missing_outdir', 'CerUPP:Plot:KeldyshDiagOutdirMissing', ...
        ['Skipping Keldysh diagnostic plot because outdir is empty. ', ...
         'No fallback to pwd is allowed.'], ...
        save_outputs_as_fig, save_outputs_as_png, phase_tag);
    if ~ok_session
        return;
    end

    i_lookup = double(i_lookup_wm2(:));
    w_lookup = double(w_lookup_sinv(:));
    valid = isfinite(i_lookup) & (i_lookup > 0) & isfinite(w_lookup) & (w_lookup >= 0);
    i_lookup = i_lookup(valid);
    w_lookup = w_lookup(valid);
    if numel(i_lookup) < 2
        return;
    end

    [i_lookup, sort_idx] = sort(i_lookup, 'ascend');
    w_lookup = w_lookup(sort_idx);
    keep = [true; diff(i_lookup) > 0];
    i_lookup = i_lookup(keep);
    w_lookup = w_lookup(keep);
    if numel(i_lookup) < 2
        return;
    end

    k_vec = double(k_power_vec(:));
    sigma_vec = max(double(sigma_k_vec(:)), 0);
    i_display_min_wm2 = display_i_min_wm2;
    i_display_max_wm2 = display_i_max_wm2;
    if ~(isfinite(i_display_min_wm2) && (i_display_min_wm2 > 0))
        i_display_min_wm2 = i_lookup(1);
    end
    if ~(isfinite(i_display_max_wm2) && (i_display_max_wm2 > i_display_min_wm2))
        i_display_max_wm2 = i_lookup(end);
    end
    i_lookup_cm2 = [i_display_min_wm2; i_display_max_wm2] ./ 1e4;
    i_plot_min_cm2 = 10.^floor(log10(max(i_lookup_cm2(1), realmin('double'))));
    i_plot_max_seed = max(i_lookup_cm2(end), i_plot_min_cm2 .* (1 + eps('double')));
    i_plot_max_cm2 = 10.^ceil(log10(i_plot_max_seed));
    if ~(isfinite(i_plot_min_cm2) && isfinite(i_plot_max_cm2) && ...
            (i_plot_min_cm2 > 0) && (i_plot_max_cm2 > i_plot_min_cm2))
        i_plot_min_cm2 = 1e11;
        i_plot_max_cm2 = 1e14;
    end
    diag_policy = struct( ...
        'i_zero_below_wm2', double(struct_utils.opt_struct_field( ...
            plot_policy_in, 'zero_rate_below_wm2', i_lookup(1))), ...
        'i_lut_min_wm2', double(struct_utils.opt_struct_field( ...
            plot_policy_in, 'lut_i_min_wm2', i_lookup(1))), ...
        'i_lut_max_wm2', double(struct_utils.opt_struct_field( ...
            plot_policy_in, 'lut_i_max_wm2', i_lookup(end))), ...
        'clamp_w_interp', logical(struct_utils.opt_struct_field( ...
            plot_policy_in, 'clamp_w_interp', true)), ...
        'w_min_clamp_value', double(struct_utils.opt_struct_field( ...
            plot_policy_in, 'w_min_clamp_value', max(real(w_lookup(1)), 0))), ...
        'w_max_clamp_value', double(struct_utils.opt_struct_field( ...
            plot_policy_in, 'w_max_clamp_value', max(real(w_lookup(end)), 0))), ...
        'show_clamp_markers', show_clamp_markers);

    i_cm2_full = logspace(log10(i_plot_min_cm2), log10(i_plot_max_cm2), 400);
    keldysh_diag_specs = struct( ...
        'session', {session}, ...
        'i_cm2', {i_cm2_full}, ...
        'x_limits_cm2', {[i_cm2_full(1), i_cm2_full(end)]}, ...
        'title_suffix', {sprintf(' [%s]', display_range_label)}, ...
        'savefig_warn_id', {'CerUPP:Plot:KeldyshDiagSaveFigFailed'}, ...
        'png_warn_id', {'CerUPP:Plot:KeldyshDiagSavePngFailed'});

    if emit_fixed_window_debug
        [debug_session, run_warn_state, ok_debug_session] = plot_utils_begin_diagnostic_session_local( ...
            outdir, 'debug_keldysh_ofi_rate_diagnostic_fixed_window', run_warn_state, show_plots_flag, ...
            'keldysh_diag_debug_missing_outdir', 'CerUPP:Plot:KeldyshDiagDebugOutdirMissing', ...
            ['Skipping fixed-window Keldysh diagnostic debug plot because outdir is empty. ', ...
             'No fallback to pwd is allowed.'], ...
            save_outputs_as_fig, save_outputs_as_png, phase_tag);
        if ok_debug_session
            i_cm2_debug = logspace(11, 14, 400);
            keldysh_diag_specs(end + 1) = struct( ...
                'session', debug_session, ...
                'i_cm2', i_cm2_debug, ...
                'x_limits_cm2', [1e11, 1e14], ...
                'title_suffix', ' [debug fixed window 1e11-1e14 W/cm^2]', ...
                'savefig_warn_id', 'CerUPP:Plot:KeldyshDiagDebugSaveFigFailed', ...
                'png_warn_id', 'CerUPP:Plot:KeldyshDiagDebugSavePngFailed');
        end
    end

    for diag_idx = 1:numel(keldysh_diag_specs)
        diag_spec = keldysh_diag_specs(diag_idx);
        [w_keld_vol_now, w_mpi_vol_now, has_mpi_model_now] = ...
            plot_utils_eval_keldysh_rate_diagnostic_curves_local( ...
                diag_spec.i_cm2, i_lookup, w_lookup, k_vec, sigma_vec, ...
                rho_nt_keldysh_norm_m3, rho_nt_m3, diag_policy);
        run_warn_state = plot_utils_render_keldysh_rate_diagnostic_local( ...
            diag_spec.session, run_warn_state, diag_spec.i_cm2, w_keld_vol_now, ...
            w_mpi_vol_now, has_mpi_model_now, rho_nt_keldysh_norm_m3, rho_nt_m3, ...
            diag_spec.x_limits_cm2, diag_spec.title_suffix, diag_policy, ...
            diag_spec.savefig_warn_id, diag_spec.png_warn_id);
    end
end

function [w_keld_vol_cgs, w_mpi_vol_cgs, has_mpi_model] = ...
        plot_utils_eval_keldysh_rate_diagnostic_curves_local(i_cm2, i_lookup, w_lookup, k_vec, sigma_vec, ...
        rho_nt_keldysh_norm_m3, rho_nt_m3, diag_policy)
% Evaluate the volumetric display curves for the current Keldysh W_site(I)
% law and any configured static-MPI comparison branch on one intensity
% display grid.

    i_m2 = double(i_cm2(:)) .* 1e4;
    w_keld = zeros(size(i_m2));

    if nargin < 8 || isempty(diag_policy)
        diag_policy = struct();
    end
    i_min = double(struct_utils.opt_struct_field(diag_policy, 'i_lut_min_wm2', i_lookup(1)));
    i_max = double(struct_utils.opt_struct_field(diag_policy, 'i_lut_max_wm2', i_lookup(end)));
    i_zero_below = double(struct_utils.opt_struct_field(diag_policy, 'i_zero_below_wm2', i_min));
    clamp_w_interp = logical(struct_utils.opt_struct_field(diag_policy, 'clamp_w_interp', true));
    w_min_clamp_value = max(double(struct_utils.opt_struct_field( ...
        diag_policy, 'w_min_clamp_value', max(real(w_lookup(1)), 0))), 0);
    w_max_clamp_value = max(double(struct_utils.opt_struct_field( ...
        diag_policy, 'w_max_clamp_value', max(real(w_lookup(end)), 0))), 0);
    w_floor = max(w_lookup, realmin);
    log_i_lookup = log(i_lookup);
    log_w_lookup = log(w_floor);
    loglinear_interp = griddedInterpolant(log_i_lookup, log_w_lookup, 'linear', 'nearest');

    zero_mask = false(size(i_m2));
    low_clamp_mask = false(size(i_m2));
    high_mask = false(size(i_m2));
    if isfinite(i_zero_below)
        zero_mask = (i_m2 < i_zero_below);
    end
    if isfinite(i_min)
        low_clamp_mask = (i_m2 < i_min) & ~zero_mask;
    end
    if isfinite(i_max)
        high_mask = (i_m2 > i_max);
    end
    within_mask = ~(zero_mask | low_clamp_mask | high_mask);
    if any(within_mask)
        iq = i_m2(within_mask);
        w_keld(within_mask) = exp(loglinear_interp(log(max(iq, realmin('double')))));
    end
    if any(low_clamp_mask)
        if clamp_w_interp
            w_keld(low_clamp_mask) = w_min_clamp_value;
        else
            w_keld(low_clamp_mask) = 0;
        end
    end
    if any(high_mask)
        if clamp_w_interp
            w_keld(high_mask) = w_max_clamp_value;
        else
            iq = min(max(i_m2(high_mask), i_min), i_max);
            w_keld(high_mask) = exp(loglinear_interp(log(max(iq, realmin('double')))));
        end
    end
    w_keld(zero_mask) = 0;
    w_keld(~isfinite(w_keld)) = NaN;

    rho_nt_norm_cgs = 1e-6 * double(rho_nt_keldysh_norm_m3);
    if ~(isfinite(rho_nt_norm_cgs) && (rho_nt_norm_cgs > 0))
        error('CerUPP:Plot:InvalidKeldyshNormDensity', ...
            ['Keldysh diagnostic plot requires a finite positive rho_nt_keldysh_norm_m3 ', ...
             'to build the volumetric W_plot axis for the current CerUPP W_site(I) display.']);
    end
    w_keld_vol_cgs = rho_nt_norm_cgs .* w_keld;

    w_mpi = zeros(size(i_m2));
    has_mpi_model = false;
    n_terms = min(numel(k_vec), numel(sigma_vec));
    for idx_term = 1:n_terms
        ki = k_vec(idx_term);
        si = sigma_vec(idx_term);
        if ~(isfinite(ki) && isfinite(si) && (ki > 0) && (si >= 0))
            continue;
        end
        has_mpi_model = true;
        term = si .* (i_m2 .^ ki);
        term(~isfinite(term)) = realmax('double');
        w_mpi = w_mpi + term;
    end
    if has_mpi_model
        rho_nt_cgs = 1e-6 * double(rho_nt_m3);
        if ~(isfinite(rho_nt_cgs) && (rho_nt_cgs > 0))
            error('CerUPP:Plot:InvalidKeldyshNeutralDensity', ...
                ['Keldysh diagnostic plot requires a finite positive rho_nt_m3 ', ...
                 'to build the configured volumetric MPI comparison curve.']);
        end
        w_mpi_vol_cgs = rho_nt_cgs .* w_mpi;
    else
        w_mpi_vol_cgs = NaN(size(i_m2));
    end
end

function run_warn_state = plot_utils_render_keldysh_rate_diagnostic_local( ...
        session, run_warn_state, i_cm2, w_keld_vol_cgs, w_mpi_vol_cgs, has_mpi_model, ...
        rho_nt_keldysh_norm_m3, rho_nt_m3, x_limits_cm2, title_suffix, diag_policy, savefig_warn_id, png_warn_id)
% Render one single-panel volumetric Keldysh diagnostic figure.

    f = plot_support_utils.open_figure(session.visible_now, false);
    set(f, 'Color', 'w');
    ax1 = axes('Parent', f);
    w_keld_plot = w_keld_vol_cgs;
    w_keld_plot(~isfinite(w_keld_plot) | (w_keld_plot <= 0)) = NaN;
    w_mpi_plot = w_mpi_vol_cgs;
    w_mpi_plot(~isfinite(w_mpi_plot) | (w_mpi_plot <= 0)) = NaN;
    clamp_note = '';
    if nargin >= 11 && isstruct(diag_policy)
        zero_cm2 = double(struct_utils.opt_struct_field(diag_policy, 'i_zero_below_wm2', NaN)) ./ 1e4;
        lut_min_cm2 = double(struct_utils.opt_struct_field(diag_policy, 'i_lut_min_wm2', NaN)) ./ 1e4;
        lut_max_cm2 = double(struct_utils.opt_struct_field(diag_policy, 'i_lut_max_wm2', NaN)) ./ 1e4;
        clamp_w_interp = logical(struct_utils.opt_struct_field(diag_policy, 'clamp_w_interp', true));
        if isfinite(zero_cm2) && isfinite(lut_min_cm2) && (zero_cm2 < lut_min_cm2) && clamp_w_interp
            clamp_note = sprintf([ ...
                'runtime policy: W=0 below the LUT floor %.3e W/cm^2; ', ...
                'configured zero floor %.3e W/cm^2 stays zero and does not create a positive shelf; ', ...
                'upper-edge clamp above %.3e W/cm^2'], ...
                lut_min_cm2, zero_cm2, lut_max_cm2);
        elseif isfinite(zero_cm2) && isfinite(lut_max_cm2) && clamp_w_interp
            clamp_note = sprintf('runtime policy: W=0 below %.3e W/cm^2, upper-edge clamp above %.3e W/cm^2', ...
                zero_cm2, lut_max_cm2);
        elseif isfinite(zero_cm2)
            clamp_note = sprintf('runtime policy: W=0 below %.3e W/cm^2', zero_cm2);
        end
    end
    hold(ax1, 'on');
    loglog(ax1, i_cm2, w_keld_plot, 'k-', 'LineWidth', 2.2);
    if has_mpi_model
        loglog(ax1, i_cm2, w_mpi_plot, '--', 'Color', [0.000, 0.447, 0.741], 'LineWidth', 1.8);
    end
    if nargin >= 11 && isstruct(diag_policy) && logical(struct_utils.opt_struct_field(diag_policy, 'show_clamp_markers', true))
        zero_cm2 = double(struct_utils.opt_struct_field(diag_policy, 'i_zero_below_wm2', NaN)) ./ 1e4;
        lut_min_cm2 = double(struct_utils.opt_struct_field(diag_policy, 'i_lut_min_wm2', NaN)) ./ 1e4;
        lut_max_cm2 = double(struct_utils.opt_struct_field(diag_policy, 'i_lut_max_wm2', NaN)) ./ 1e4;
        if isfinite(zero_cm2) && (zero_cm2 >= x_limits_cm2(1)) && (zero_cm2 <= x_limits_cm2(2))
            xline(ax1, zero_cm2, ':', 'Color', [0.35, 0.35, 0.35], 'LineWidth', 1.2);
        end
        if isfinite(lut_min_cm2) && (lut_min_cm2 >= x_limits_cm2(1)) && (lut_min_cm2 <= x_limits_cm2(2))
            xline(ax1, lut_min_cm2, '--', 'Color', [0.850, 0.325, 0.098], 'LineWidth', 1.0);
        end
        if isfinite(lut_max_cm2) && (lut_max_cm2 >= x_limits_cm2(1)) && (lut_max_cm2 <= x_limits_cm2(2))
            xline(ax1, lut_max_cm2, '--', 'Color', [0.494, 0.184, 0.556], 'LineWidth', 1.0);
        end
    end
    hold(ax1, 'off');
    grid(ax1, 'on');
    xlim(ax1, x_limits_cm2);
    xlabel(ax1, 'Intensity [W/cm^2] (display axis; 1 W/cm^2 = 1e4 W/m^2)');
    ylabel(ax1, 'Volumetric OFI rate W [s^-1 cm^-3]');
    if isempty(clamp_note)
        title(ax1, sprintf(['Volumetric Keldysh OFI diagnostic%s ', ...
            '(W_{plot}=10^{-6} rho_{nt,Knorm} W_{site}, rho_{nt,Knorm}=%.3e m^-3, rho_{nt}=%.3e m^-3)'], ...
            title_suffix, double(rho_nt_keldysh_norm_m3), double(rho_nt_m3)));
    else
        title(ax1, sprintf(['Volumetric Keldysh OFI diagnostic%s ', ...
            '(W_{plot}=10^{-6} rho_{nt,Knorm} W_{site}, rho_{nt,Knorm}=%.3e m^-3, rho_{nt}=%.3e m^-3)\n%s'], ...
            title_suffix, double(rho_nt_keldysh_norm_m3), double(rho_nt_m3), clamp_note));
    end
    leg_ax1 = {'CerUPP W_{plot} = 10^{-6} rho_{nt,Knorm} W_{site}'};
    if has_mpi_model
        leg_ax1{end+1} = 'Configured static MPI comparison W_{MPI} = 10^{-6} rho_{nt} sigma_K I_{SI}^K';
    end
    legend(ax1, leg_ax1, 'Location', 'southoutside');

    run_warn_state = plot_utils_finalize_diagnostic_figure_local( ...
        f, session, run_warn_state, ...
        savefig_warn_id, ...
        'Failed to save Keldysh diagnostic FIG "%s": %s', ...
        'plot_export_failed_cerupp:keldyshdiagsavepngfailed', ...
        png_warn_id);
end

function [session, run_warn_state, ok] = plot_utils_begin_diagnostic_session_local( ...
    outdir, fig_name_base, run_warn_state, show_plots_flag, ...
    missing_outdir_warn_key, missing_outdir_warn_id, missing_outdir_msg, ...
    save_outputs_as_fig, save_outputs_as_png, phase_tag)
% Validate the explicit outdir / save-policy inputs and return one plot session.
% Returns ok=false with a recorded warning when outdir is missing or invalid.
% When ok=true, the helper resolves the visible/close behavior from
% show_plots_flag, records one headless-visible downgrade warning when
% needed, and initializes the common session shell used by the caller.

    if nargin < 3 || ~isstruct(run_warn_state)
        run_warn_state = struct();
    end
    session = plot_utils_empty_session_local();
    ok = false;
    if nargin < 10 || isempty(phase_tag)
        phase_tag = run_warn_state_utils.phase_end();
    end
    phase_tag = run_warn_state_utils.canonical_phase_name(phase_tag);
    fig_name_txt = char(string(fig_name_base));
    missing_warn_key = 'diagnostic_outdir_missing';
    if nargin >= 5 && ~isempty(missing_outdir_warn_key)
        missing_warn_key = char(string(missing_outdir_warn_key));
    end
    missing_warn_id = 'CerUPP:Plot:DiagnosticOutdirMissing';
    if nargin >= 6 && ~isempty(missing_outdir_warn_id)
        missing_warn_id = char(string(missing_outdir_warn_id));
    end
    missing_outdir_msg_txt = sprintf( ...
        'Skipping diagnostic plot "%s" because outdir is empty. No fallback to pwd is allowed.', ...
        fig_name_txt);
    if nargin >= 7 && ~isempty(missing_outdir_msg)
        missing_outdir_msg_txt = char(string(missing_outdir_msg));
    end
    if nargin < 1 || isempty(outdir)
        if ~isempty(missing_warn_id)
            run_warn_state = run_warn_state_utils.emit_warn_once_with_phase_message( ...
                run_warn_state, phase_tag, missing_warn_key, missing_warn_id, '%s', missing_outdir_msg_txt);
        else
            run_warn_state = run_warn_state_utils.record_warning_phase_event( ...
                run_warn_state, phase_tag, 'CerUPP:Plot:DiagnosticOutdirMissing', ...
                missing_outdir_msg_txt, 'direct_record');
        end
        return;
    end
    if isstring(outdir) && isscalar(outdir)
        outdir = char(outdir);
    end
    if ~ischar(outdir) || isempty(strtrim(outdir))
        invalid_outdir_msg = sprintf( ...
            'Skipping diagnostic plot "%s" because outdir is invalid or blank. No fallback to pwd is allowed.', ...
            fig_name_txt);
        run_warn_state = run_warn_state_utils.emit_warn_once_with_phase_message( ...
            run_warn_state, phase_tag, [missing_warn_key '_invalid'], ...
            'CerUPP:Plot:DiagnosticOutdirInvalid', '%s', invalid_outdir_msg);
        return;
    end
    if nargin < 8 || isempty(save_outputs_as_fig) || nargin < 9 || isempty(save_outputs_as_png)
        error('CerUPP:Plot:MissingDiagnosticSavePolicy', ...
            ['plot_utils_begin_diagnostic_session_local requires explicit ', ...
             'save_outputs_as_fig and save_outputs_as_png policy inputs.']);
    end
    [ok_save_fig, save_outputs_as_fig] = plot_support_utils.parse_bool_like(save_outputs_as_fig);
    if ~ok_save_fig
        error('CerUPP:Plot:InvalidDiagnosticSaveFigPolicy', ...
            'save_outputs_as_fig must be a logical scalar or numeric in {0,1} for diagnostic sessions.');
    end
    [ok_save_png, save_outputs_as_png] = plot_support_utils.parse_bool_like(save_outputs_as_png);
    if ~ok_save_png
        error('CerUPP:Plot:InvalidDiagnosticSavePngPolicy', ...
            'save_outputs_as_png must be a logical scalar or numeric in {0,1} for diagnostic sessions.');
    end
    [visible_now, close_after] = plot_utils_resolve_show_plots_lifecycle_local(show_plots_flag);
    [show_plots_ok, show_plots_requested] = plot_support_utils.parse_bool_like(show_plots_flag);
    if show_plots_ok && show_plots_requested && ~visible_now && ~plot_utils_desktop_available_local()
        run_warn_state = plot_utils_record_headless_visible_downgrade_local(run_warn_state, phase_tag);
    end
    session = plot_utils_init_explicit_session_local( ...
        outdir, fig_name_base, save_outputs_as_fig, save_outputs_as_png, ...
        'visible', visible_now, 'close_figure', close_after);
    session.phase_tag = phase_tag;
    ok = true;
end

function run_warn_state = plot_utils_record_headless_visible_downgrade_local(run_warn_state, phase_tag)
% Emit one canonical plot-phase notice when visible figures are unavailable.

    if nargin < 2 || isempty(phase_tag)
        phase_tag = run_warn_state_utils.phase_end();
    end
    phase_tag = run_warn_state_utils.canonical_phase_name(phase_tag);
    downgrade_msg = ['Visible diagnostic plot requests were downgraded to hidden auto-closed figures ' ...
        'because desktop graphics are unavailable in this session.'];
    run_warn_state = run_warn_state_utils.emit_warn_once_with_phase_message( ...
        run_warn_state, phase_tag, 'diagnostic_visible_headless_downgrade', ...
        'CerUPP:Plot:HeadlessVisibleDowngrade', '%s', downgrade_msg);
end

function [visible_now, close_after] = plot_utils_resolve_show_plots_lifecycle_local(show_plots_flag)
% Shared visible/close policy for specialized diagnostic figures.
% Visibility is enabled only when show_plots_flag is truthy and desktop
% graphics are available (usejava('desktop')); otherwise figures stay
% hidden and are closed after export. Callers may surface that downgrade
% through an explicit warning/status path.

    visible_now = false;
    close_after = true;
    if isscalar(show_plots_flag) && ...
            (islogical(show_plots_flag) || ...
             (isnumeric(show_plots_flag) && isreal(show_plots_flag) && isfinite(show_plots_flag))) && ...
            logical(show_plots_flag) && plot_utils_desktop_available_local()
        visible_now = true;
        close_after = false;
    end
end

function run_warn_state = plot_utils_finalize_diagnostic_figure_local( ...
    fig_handle, session, run_warn_state, savefig_warn_id, savefig_warn_fmt, png_warn_key, png_warn_id)
% Finalize one diagnostic figure via the shared staged export policy:
% attempt FIG save first when enabled, then attempt PNG export through the
% fallback/accounting path, and finally close the figure if requested by
% the session policy.

    phase_tag = run_warn_state_utils.phase_end();
    record_failure_tag = 'png_export';
    if isstruct(session) && isfield(session, 'phase_tag') && ~isempty(session.phase_tag)
        phase_tag = run_warn_state_utils.canonical_phase_name(session.phase_tag);
    end
    if isstruct(session) && isfield(session, 'record_failure_tag') && ~isempty(session.record_failure_tag)
        record_failure_tag = char(string(session.record_failure_tag));
    end
    run_warn_state = plot_utils_save_figure_outputs_impl( ...
        fig_handle, session.save_name_new, ...
        session.save_outputs_as_fig, session.save_outputs_as_png, ...
        run_warn_state, phase_tag, session.close_figure_now, ...
        'do_warn', true, ...
        'savefig_warn_id', savefig_warn_id, ...
        'savefig_warn_fmt', savefig_warn_fmt, ...
        'png_warn_key', png_warn_key, ...
        'png_warn_id', png_warn_id, ...
        'record_failure_tag', record_failure_tag);
end

function session = plot_utils_empty_session_local()
% Canonical inactive diagnostic-session struct used for both success and failure paths.

    session = struct( ...
        'outdir', '', ...
        'save_name_new', '', ...
        'plot_args', {cell(0, 1)}, ...
        'save_outputs_as_fig', false, ...
        'save_outputs_as_png', false, ...
        'do_save', false, ...
        'close_figure_now', true, ...
        'visible_now', false, ...
        'phase_tag', run_warn_state_utils.phase_end(), ...
        'record_failure_tag', 'png_export');
end

function session = plot_utils_init_session_local(save_name, save_outputs_as_fig, save_outputs_as_png, varargin)
% Shared plot-session shell for resolved save gating and figure policy.
% DO_SAVE becomes true only when a nonempty resolved save stem exists and
% at least one save flag is enabled. Optional close_figure/visible
% overrides replace the default lifecycle policy in the returned session.
% Directory creation is deferred until an actual save is attempted, so
% non-saving sessions do not mkdir side effects.

    [outdir, save_name_new, ~, plot_args, force_close_figure, force_visible] = ...
        plot_utils_resolve_plot_output_target_impl(save_name, 'output_plots', varargin{:});
    session = plot_utils_empty_session_local();
    session.outdir = outdir;
    session.save_name_new = save_name_new;
    session.plot_args = plot_args;
    save_outputs_as_fig = struct_utils.normalize_bool_scalar( ...
        save_outputs_as_fig, 'save_outputs_as_fig', ...
        'CerUPP:Plot:SessionSaveFigFlag');
    save_outputs_as_png = struct_utils.normalize_bool_scalar( ...
        save_outputs_as_png, 'save_outputs_as_png', ...
        'CerUPP:Plot:SessionSavePngFlag');
    session.save_outputs_as_fig = ~isempty(save_name_new) && save_outputs_as_fig;
    session.save_outputs_as_png = ~isempty(save_name_new) && save_outputs_as_png;
    session.do_save = session.save_outputs_as_fig || session.save_outputs_as_png;
    if ~isempty(force_close_figure)
        session.close_figure_now = force_close_figure;
    end
    if ~isempty(force_visible)
        session.visible_now = force_visible;
    end
end

function session = plot_utils_init_explicit_session_local( ...
        outdir, fig_name_base, save_outputs_as_fig, save_outputs_as_png, varargin)
% Shared plot-session shell for specialized helpers with an already-owned explicit outdir.
% This path intentionally skips the generic output-target resolver: the
% outdir contract is already validated by the specialized caller, and the
% figure name must remain a bare stem rather than a path-carrying target.

    if nargin < 1 || isempty(outdir)
        error('CerUPP:Plot:ExplicitSessionOutdirMissing', ...
            'plot_utils_init_explicit_session_local requires a nonempty explicit outdir.');
    end
    if isstring(outdir) && isscalar(outdir)
        outdir = char(outdir);
    end
    outdir = strtrim(char(outdir));
    if isempty(outdir)
        error('CerUPP:Plot:ExplicitSessionOutdirBlank', ...
            'plot_utils_init_explicit_session_local requires a nonblank explicit outdir.');
    end
    if isstring(fig_name_base) && isscalar(fig_name_base)
        fig_name_base = char(fig_name_base);
    end
    if ~(ischar(fig_name_base) && ~isempty(strtrim(fig_name_base)))
        error('CerUPP:Plot:ExplicitSessionNameMissing', ...
            'plot_utils_init_explicit_session_local requires a nonempty figure-stem name.');
    end

    explicit_args = varargin;
    [explicit_args, found_close_figure, close_figure_override] = plot_utils_consume_named_option_local( ...
        explicit_args, {'close_figure'}, @plot_support_utils.parse_bool_like);
    [explicit_args, found_visible, visible_override] = plot_utils_consume_named_option_local( ...
        explicit_args, {'visible'}, @plot_utils_parse_visible_override_local);
    if ~isempty(explicit_args)
        error('CerUPP:PlotArgs:UnknownExplicitSessionOption', ...
            'Unknown explicit-session option(s): %s', ...
            plot_utils_named_option_summary_local(explicit_args));
    end

    [save_dir, base_raw, ~] = fileparts(char(fig_name_base));
    if ~isempty(save_dir)
        error('CerUPP:Plot:ExplicitSessionNameHasDir', ...
            ['Explicit diagnostic sessions require fig_name_base without a directory path. ', ...
             'Got "%s".'], char(fig_name_base));
    end
    base_name = strtrim(base_raw);
    if isempty(base_name)
        error('CerUPP:Plot:ExplicitSessionNameBlank', ...
            'Explicit diagnostic sessions require a nonblank figure-stem name.');
    end

    session = plot_utils_empty_session_local();
    session.outdir = outdir;
    session.save_name_new = fullfile(outdir, base_name);
    session.save_outputs_as_fig = struct_utils.normalize_bool_scalar( ...
        save_outputs_as_fig, 'save_outputs_as_fig', ...
        'CerUPP:Plot:ExplicitSessionSaveFigFlag');
    session.save_outputs_as_png = struct_utils.normalize_bool_scalar( ...
        save_outputs_as_png, 'save_outputs_as_png', ...
        'CerUPP:Plot:ExplicitSessionSavePngFlag');
    session.do_save = session.save_outputs_as_fig || session.save_outputs_as_png;
    if found_close_figure && ~isempty(close_figure_override)
        session.close_figure_now = close_figure_override;
    end
    if found_visible && ~isempty(visible_override)
        session.visible_now = visible_override;
    end
end

function tf = plot_utils_desktop_available_local()
% Query the current session-level desktop GUI availability.

    tf = usejava('desktop');
end

function [outdir_use, save_name_new, base_name, passthrough_args, close_figure_override, visible_override] = plot_utils_resolve_plot_output_target_impl(save_name, default_outdir, varargin)
% Plot-utils-owned output-target parser for figure session setup.
% Keeps precedence consistent across make_plot/make_isosurface_plot/make_scatter3_plot:
% 1) save_name directory (if provided) wins
% 2) otherwise use default_outdir or 'outdir' override from varargin
%
% Recognized optional key/value pairs in varargin:
% - 'outdir', <char|string scalar>
% - 'close_figure', <logical|numeric scalar>
% - 'visible', <logical|numeric scalar|'on'|'off'>
%
% Outputs:
% - outdir_use: resolved output directory
% - save_name_new: full output stem (without extension), or '' if no base
% - base_name: trimmed base filename from save_name
% - passthrough_args: varargin with recognized keys removed
% - close_figure_override: [] when not provided; otherwise logical scalar
% - visible_override: [] when not provided; otherwise logical scalar

    if nargin < 2 || isempty(default_outdir) || ...
            ~(ischar(default_outdir) || (isstring(default_outdir) && isscalar(default_outdir)))
        default_outdir = 'output_plots';
    end
    outdir_use = char(default_outdir);
    close_figure_override = [];
    visible_override = [];

    passthrough_args = {};
    ii = 1;
    while ii <= numel(varargin)
        key = varargin{ii};
        is_key = (ischar(key) || (isstring(key) && isscalar(key)));
        if is_key
            key_str = strtrim(char(key));
            has_val = (ii < numel(varargin));
            if strcmpi(key_str, 'outdir')
                if ~has_val
                    error('CerUPP:PlotArgs:OutdirMissingValue', ...
                        '''outdir'' must be followed by a directory string.');
                end
                val = varargin{ii+1};
                if ~(ischar(val) || (isstring(val) && isscalar(val)))
                    error('CerUPP:PlotArgs:OutdirValueType', ...
                        '''outdir'' value must be char or string scalar; got %s.', class(val));
                end
                val_char = strtrim(char(val));
                if isempty(val_char)
                    error('CerUPP:PlotArgs:OutdirEmptyValue', ...
                        '''outdir'' value must be a nonempty directory string.');
                end
                outdir_use = val_char;
                ii = ii + 2;
                continue;
            elseif strcmpi(key_str, 'close_figure')
                if ~has_val
                    error('CerUPP:PlotArgs:CloseFigureMissingValue', ...
                        '''close_figure'' must be followed by a logical scalar or numeric in {0,1}.');
                end
                val = varargin{ii+1};
                [ok_parse, close_figure_override] = plot_support_utils.parse_bool_like(val);
                if ~ok_parse
                    error('CerUPP:PlotArgs:CloseFigureValueType', ...
                        ['''close_figure'' value must be a logical scalar or numeric in {0,1}; ', ...
                         'got %s.'], class(val));
                end
                ii = ii + 2;
                continue;
            elseif strcmpi(key_str, 'visible')
                if ~has_val
                    error('CerUPP:PlotArgs:VisibleMissingValue', ...
                        ['''visible'' must be followed by a logical scalar, numeric in {0,1}, ', ...
                         'or ''on''/''off''.']);
                end
                val = varargin{ii+1};
                [ok_parse, visible_override] = plot_utils_parse_visible_override_local(val);
                if ~ok_parse
                    error('CerUPP:PlotArgs:VisibleValueType', ...
                        ['''visible'' value must be a logical scalar, numeric in {0,1}, ', ...
                         'or ''on''/''off''; got %s.'], class(val));
                end
                ii = ii + 2;
                continue;
            end
        end

        passthrough_args{end+1} = varargin{ii}; %#ok<AGROW>
        ii = ii + 1;
    end

    [save_dir, base_raw, ~] = fileparts(char(save_name));
    if ~isempty(save_dir)
        outdir_use = save_dir;
    end

    base_name = strtrim(base_raw);
    if ~isempty(base_name)
        save_name_new = fullfile(outdir_use, base_name);
    else
        save_name_new = '';
    end
end

function lambda_m = plot_utils_require_lambda_axis_window_local(lambda_window)
% Require a finite positive wavelength axis before building conversion factors.

    if ~(isnumeric(lambda_window) && isreal(lambda_window) && isvector(lambda_window) && ~isempty(lambda_window))
        error('CerUPP:Plot:InvalidSpectralLambdaAxisWindow', ...
            'lambda_window must be a nonempty real numeric vector.');
    end
    lambda_m = double(lambda_window(:).');
    if any(~isfinite(lambda_m) | (lambda_m <= 0))
        error('CerUPP:Plot:InvalidSpectralLambdaAxisWindow', ...
            'lambda_window must contain only finite positive values.');
    end
end

function value_out = plot_utils_require_positive_real_scalar_local(value_in, value_name, err_id)
% Require a finite positive real scalar at the public axis-context boundary.

    if nargin < 2 || isempty(value_name)
        value_name = 'value';
    end
    if nargin < 3 || isempty(err_id)
        err_id = 'CerUPP:Plot:InvalidPositiveRealScalar';
    end
    if ~(isnumeric(value_in) && isreal(value_in) && isscalar(value_in) && isfinite(value_in) && (value_in > 0))
        error(err_id, '%s must be a finite positive real scalar.', value_name);
    end
    value_out = double(value_in);
end

function [plot_args, do_warn] = plot_utils_strip_warn_flag_local(plot_args)
% Strip canonical public warn controls from Name/Value plot args.
% Invalid or unrecognized pairs are left in plot_args unchanged.

    [plot_args, do_warn] = plot_utils_normalize_option_bundle_with_warn_local( ...
        plot_args, struct([]));
end

function [plot_args, do_warn, parsed_opts] = plot_utils_normalize_option_bundle_with_warn_local( ...
        plot_args, option_specs)
% Canonical one-pass normalization for warn plus specialized option bundles.

    if nargin < 2 || isempty(option_specs)
        option_specs = struct([]);
    end
    warn_spec = struct( ...
        'field', 'warn', ...
        'names', {{'warn'}}, ...
        'parse_fn', @plot_support_utils.parse_bool_like, ...
        'default_value', true);
    [all_opts, plot_args] = plot_utils_parse_option_bundle_local( ...
        plot_args, [warn_spec, option_specs]);
    do_warn = all_opts.warn;
    if isempty(option_specs)
        parsed_opts = struct();
    else
        parsed_opts = rmfield(all_opts, 'warn');
    end
end

function status = plot_utils_save_png_with_fallback_backend_impl(fig_handle, png_path, varargin)
% Plot-owned low-level PNG backend wrapper around exportgraphics with print fallback.
% Contract/input-validation errors still raise immediately; STATUS reports
% backend export fallback outcomes only. Public warn controls are stripped
% here because warning/accounting policy lives above this backend.
% STATUS fields are: ok, used_print_fallback, reason,
% export_error_id, export_error_message, and print_error_message.
% exportgraphics failure can still end with STATUS.ok=true when the print
% fallback succeeds.

    [varargin, ~] = plot_utils_strip_warn_flag_local(varargin);
    status = struct( ...
        'ok', true, ...
        'used_print_fallback', false, ...
        'reason', '', ...
        'export_error_id', '', ...
        'export_error_message', '', ...
        'print_error_message', '');
    fallback_resolution = 1200;
    if mod(numel(varargin), 2) ~= 0
        error('plot_utils:InvalidPngBackendNameValuePairs', ...
            ['exportgraphics options must be provided as name/value pairs ' ...
             '(even argument count). Got %d option args.'], numel(varargin));
    end
    for idx_opt = 1:2:numel(varargin)
        key = varargin{idx_opt};
        if isstring(key) && isscalar(key)
            key = char(key);
        end
        if ischar(key) && strcmpi(strtrim(key), 'Resolution')
            val = varargin{idx_opt + 1};
            if isnumeric(val) && isscalar(val) && isreal(val) && isfinite(val) && (val > 0)
                fallback_resolution = max(1, round(double(val)));
            end
        end
    end

    try
        exportgraphics(fig_handle, png_path, varargin{:});
        return;
    catch me_export
        if strcmp(me_export.identifier, 'MATLAB:UndefinedFunction')
            status.used_print_fallback = true;
            status.export_error_id = me_export.identifier;
            status.export_error_message = me_export.message;
            status.reason = 'missing_exportgraphics';
        elseif plot_utils_exportgraphics_contract_error_local(me_export)
            plot_utils_throw_exportgraphics_contract_error_local(png_path, me_export);
        elseif plot_utils_exportgraphics_runtime_fallback_local(me_export)
            status.used_print_fallback = true;
            status.export_error_id = me_export.identifier;
            status.export_error_message = me_export.message;
            status.reason = 'exportgraphics_failed';
        else
            rethrow(me_export);
        end
    end

    try
        print(fig_handle, png_path, '-dpng', sprintf('-r%d', fallback_resolution));
    catch me_print
        status.ok = false;
        status.print_error_message = me_print.message;
    end
end

function tf = plot_utils_exportgraphics_contract_error_local(me_export)
% Classify clearly caller-owned exportgraphics option/input failures.

    err_id = lower(strtrim(char(string(me_export.identifier))));
    err_msg = lower(strtrim(char(string(me_export.message))));
    tf = any(startsWith(err_id, {'matlab:validation:', 'matlab:validators:', 'matlab:inputparser:'})) || ...
        any(contains(err_msg, { ...
            'invalid', ...
            'must be', ...
            'must have', ...
            'expected', ...
            'unrecognized', ...
            'unknown option', ...
            'unknown parameter', ...
            'parameter name', ...
            'name/value', ...
            'name-value'}));
end

function tf = plot_utils_exportgraphics_runtime_fallback_local(me_export)
% Reserve print fallback for a narrow class of backend/runtime export failures.

    err_id = lower(strtrim(char(string(me_export.identifier))));
    err_msg = lower(strtrim(char(string(me_export.message))));
    tf = any(startsWith(err_id, {'matlab:exportgraphics:', 'matlab:graphics:'})) || ...
        any(contains(err_msg, { ...
            'renderer', ...
            'opengl', ...
            'graphics system', ...
            'failed to export', ...
            'unable to export', ...
            'rendering', ...
            'headless', ...
            'java'}));
end

function plot_utils_throw_exportgraphics_contract_error_local(png_path, me_export)
% Re-throw input-owned exportgraphics failures under a plot-owned contract ID.

    export_err_id = char(string(me_export.identifier));
    if isempty(strtrim(export_err_id))
        export_err_id = '(no identifier)';
    end
    me_contract = MException('CerUPP:Plot:ExportGraphicsContractError', ...
        ['exportgraphics input/options are invalid for "%s". ', ...
         'exportgraphics error (%s): %s'], ...
        png_path, export_err_id, me_export.message);
    me_contract = addCause(me_contract, me_export);
    throwAsCaller(me_contract);
end

function [parsed_opts, passthrough_args] = plot_utils_parse_option_bundle_local( ...
        plot_args, option_specs)
% Parse specialized plot options through one shared normalization path.
% Recognized option names always hard-fail on invalid values.

    if isempty(option_specs)
        parsed_opts = struct();
        passthrough_args = plot_args;
        return;
    end
    parsed_opts = struct();
    for ii = 1:numel(option_specs)
        parsed_opts.(option_specs(ii).field) = option_specs(ii).default_value;
    end
    passthrough_args = {};
    ii = 1;
    while ii <= numel(plot_args)
        if ii == numel(plot_args)
            passthrough_args{end+1} = plot_args{ii}; %#ok<AGROW>
            break;
        end
        key = plot_args{ii};
        handled = false;
        if ischar(key) || (isstring(key) && isscalar(key))
            key_str = strtrim(char(key));
            for jj = 1:numel(option_specs)
                if any(strcmpi(key_str, option_specs(jj).names))
                    handled = true;
                    [ok_parse, value_out] = option_specs(jj).parse_fn(plot_args{ii+1});
                    if ok_parse
                        parsed_opts.(option_specs(jj).field) = value_out;
                    else
                        error('CerUPP:Plot:InvalidRecognizedOption', ...
                            ['Recognized plot option "%s" received an invalid value for %s ', ...
                             '(class=%s).'], ...
                            key_str, option_specs(jj).field, class(plot_args{ii+1}));
                    end
                    ii = ii + 2;
                    break;
                end
            end
        end
        if handled
            continue;
        end
        passthrough_args{end+1} = plot_args{ii}; %#ok<AGROW>
        ii = ii + 1;
    end
end

function [plot_args, found_opt, value_out] = plot_utils_consume_named_option_local( ...
    plot_args, option_names, parse_fn)
% Consume one named option family from a Name/Value list and hard-fail on invalid recognized values.

    if nargin < 2 || isempty(option_names)
        error('CerUPP:InvalidPlotOptionSpec', ...
            'option_names must be a nonempty cell array of option names.');
    end
    if nargin < 3 || isempty(parse_fn)
        error('CerUPP:InvalidPlotOptionSpec', ...
            'parse_fn must be provided for plot option consumption.');
    end
    found_opt = false;
    value_out = [];
    ii = 1;
    while ii <= (numel(plot_args) - 1)
        key = plot_args{ii};
        if ischar(key) || (isstring(key) && isscalar(key))
            key_str = strtrim(char(key));
            if any(strcmpi(key_str, option_names))
                [ok_parse, value_tmp] = parse_fn(plot_args{ii+1});
                if ok_parse
                    value_out = value_tmp;
                    found_opt = true;
                    plot_args(ii:ii+1) = [];
                    continue;
                end
                error('CerUPP:Plot:InvalidRecognizedOption', ...
                    ['Recognized plot option "%s" received an invalid value ', ...
                     '(class=%s).'], ...
                    key_str, class(plot_args{ii+1}));
            end
        end
        ii = ii + 1;
    end
end

function [ok_parse, value_out] = plot_utils_parse_visible_override_local(value_in)
% Parse visible overrides with the same public on/off semantics as the generic resolver.

    [ok_parse, value_out] = plot_support_utils.parse_bool_like(value_in);
    if ok_parse
        return;
    end
    if ischar(value_in) || (isstring(value_in) && isscalar(value_in))
        vis_token = lower(strtrim(char(value_in)));
        if strcmp(vis_token, 'on')
            ok_parse = true;
            value_out = true;
        elseif strcmp(vis_token, 'off')
            ok_parse = true;
            value_out = false;
        end
    end
end

function summary_txt = plot_utils_named_option_summary_local(args)
% Summarize leftover Name/Value tokens for user-facing plot option errors.

    if isempty(args)
        summary_txt = '';
        return;
    end
    key_parts = cell(1, numel(args));
    for ii = 1:numel(args)
        token = args{ii};
        if ischar(token) || (isstring(token) && isscalar(token))
            key_parts{ii} = char(string(token));
        else
            key_parts{ii} = sprintf('<%s>', class(token));
        end
    end
    summary_txt = strjoin(key_parts, ', ');
end

function [ok_parse, value_out] = plot_utils_parse_struct_scalar_local(value_in)
% Parse scalar struct payloads for hidden state-threading options.

    ok_parse = false;
    value_out = [];
    if isstruct(value_in) && isscalar(value_in)
        value_out = value_in;
        ok_parse = true;
    end
end

function run_warn_state = plot_utils_save_figure_local(fig_handle, session, run_warn_state)
% Thin adapter onto the shared plot-utils figure-export routine.
% Uses the shared FIG/PNG save path with caller-controlled warning
% emission and the default 300-DPI PNG export resolution when no explicit
% resolution override is supplied upstream.

    if nargin < 3 || isempty(run_warn_state) || ~isstruct(run_warn_state)
        run_warn_state = struct();
    end
    phase_tag = run_warn_state_utils.phase_end();
    if isstruct(session) && isfield(session, 'phase_tag') && ~isempty(session.phase_tag)
        phase_tag = run_warn_state_utils.canonical_phase_name(session.phase_tag);
    end
    record_failure_tag = 'png_export';
    if isstruct(session) && isfield(session, 'record_failure_tag') && ~isempty(session.record_failure_tag)
        record_failure_tag = char(string(session.record_failure_tag));
    end
    run_warn_state = plot_utils_save_figure_outputs_impl( ...
        fig_handle, session.save_name_new, session.save_outputs_as_fig, session.save_outputs_as_png, ...
        run_warn_state, phase_tag, false, ...
        'do_warn', session.do_warn, ...
        'savefig_warn_id', 'CerUPP:Plot:SaveFigFailed', ...
        'savefig_warn_fmt', 'Failed to save FIG "%s": %s', ...
        'png_warn_key', 'plot_export_failed', ...
        'png_warn_id', 'CerUPP:Plot:ExportGraphicsFailed', ...
        'record_failure_tag', record_failure_tag, ...
        'fig_record_failure_tag', 'fig_export', ...
        'mkdir_record_failure_tag', 'plot_output_dir_create');
end

function run_warn_state = plot_utils_save_figure_outputs_impl( ...
    fig_handle, save_stem_path, save_outputs_as_fig, save_outputs_as_png, run_warn_state, phase_tag, close_after_save, varargin)
% Shared staged save/export/close policy for figure exports owned by plot_utils.
% When enabled, FIG save is attempted first, PNG export is attempted next
% through the shared fallback/accounting path even if FIG save failed, and
% the close policy is applied only after the save/export attempts finish.
% DO_WARN controls visible warning emission only; failure accounting stays
% attached to run_warn_state even when warnings are suppressed.

    if nargin < 6 || isempty(phase_tag)
        phase_tag = run_warn_state_utils.phase_end();
    end
    if nargin < 7
        close_after_save = true;
    end
    if nargin < 5 || isempty(run_warn_state) || ~isstruct(run_warn_state)
        run_warn_state = struct();
    end
    run_warn_state = struct_utils.ensure_warned_keys_map(run_warn_state);
    export_args = varargin;
    do_warn = true;
    savefig_warn_id = 'CerUPP:Plot:SaveFigFailed';
    savefig_warn_fmt = 'Failed to save FIG "%s": %s';
    png_warn_key = 'png_export_failed';
    png_warn_id = 'CerUPP:Plot:ExportGraphicsFailed';
    record_failure_tag = '';
    fig_record_failure_tag = 'fig_export';
    mkdir_record_failure_tag = 'plot_output_dir_create';
    [export_args, found_do_warn, do_warn_value] = plot_utils_consume_named_option_local( ...
        export_args, {'do_warn'}, @plot_support_utils.parse_bool_like);
    if found_do_warn
        do_warn = do_warn_value;
    end
    [export_args, found_savefig_warn_id, savefig_warn_id_value] = plot_utils_consume_named_option_local( ...
        export_args, {'savefig_warn_id'}, @plot_support_utils.parse_char_scalar);
    if found_savefig_warn_id
        savefig_warn_id = savefig_warn_id_value;
    end
    [export_args, found_savefig_warn_fmt, savefig_warn_fmt_value] = plot_utils_consume_named_option_local( ...
        export_args, {'savefig_warn_fmt'}, @plot_support_utils.parse_char_scalar);
    if found_savefig_warn_fmt
        savefig_warn_fmt = savefig_warn_fmt_value;
    end
    [export_args, found_png_warn_key, png_warn_key_value] = plot_utils_consume_named_option_local( ...
        export_args, {'png_warn_key'}, @plot_support_utils.parse_char_scalar);
    if found_png_warn_key
        png_warn_key = png_warn_key_value;
    end
    [export_args, found_png_warn_id, png_warn_id_value] = plot_utils_consume_named_option_local( ...
        export_args, {'png_warn_id'}, @plot_support_utils.parse_char_scalar);
    if found_png_warn_id
        png_warn_id = png_warn_id_value;
    end
    [export_args, found_record_failure_tag, record_failure_tag_value] = plot_utils_consume_named_option_local( ...
        export_args, {'record_failure_tag'}, @plot_support_utils.parse_char_scalar);
    if found_record_failure_tag
        record_failure_tag = record_failure_tag_value;
    end
    [export_args, found_fig_record_failure_tag, fig_record_failure_tag_value] = plot_utils_consume_named_option_local( ...
        export_args, {'fig_record_failure_tag'}, @plot_support_utils.parse_char_scalar);
    if found_fig_record_failure_tag
        fig_record_failure_tag = fig_record_failure_tag_value;
    end
    [export_args, found_mkdir_record_failure_tag, mkdir_record_failure_tag_value] = plot_utils_consume_named_option_local( ...
        export_args, {'mkdir_record_failure_tag'}, @plot_support_utils.parse_char_scalar);
    if found_mkdir_record_failure_tag
        mkdir_record_failure_tag = mkdir_record_failure_tag_value;
    end
    save_outputs_as_fig = struct_utils.normalize_bool_scalar( ...
        save_outputs_as_fig, 'save_outputs_as_fig', ...
        'CerUPP:Plot:SaveFigureOutputsSaveFigFlag');
    save_outputs_as_png = struct_utils.normalize_bool_scalar( ...
        save_outputs_as_png, 'save_outputs_as_png', ...
        'CerUPP:Plot:SaveFigureOutputsSavePngFlag');
    do_save = save_outputs_as_fig || save_outputs_as_png;
    if isstring(save_stem_path) && isscalar(save_stem_path)
        save_stem_path = char(save_stem_path);
    end
    if ~ischar(save_stem_path)
        save_stem_path = char(string(save_stem_path));
    end
    if isempty(fig_handle) || ~isgraphics(fig_handle)
        if do_save
            invalid_handle_msg = sprintf( ...
                'Skipping requested figure export for "%s": figure handle is empty or invalid.', ...
                char(save_stem_path));
            if do_warn
                [run_warn_state, emitted_now, msg_txt, format_failed] = ...
                    run_warn_state_utils.emit_softwarn_each_time_with_phase_message( ...
                    run_warn_state, phase_tag, ...
                    'CerUPP:Plot:InvalidFigureHandle', '%s', invalid_handle_msg);
            else
                run_warn_state = run_warn_state_utils.record_warning_phase_event( ...
                    run_warn_state, phase_tag, 'CerUPP:Plot:InvalidFigureHandle', ...
                    invalid_handle_msg, 'direct_record');
            end
        end
        return;
    end
    if ~plot_utils_has_named_option_local(export_args, 'Resolution')
        export_args = [export_args, {'Resolution', 300}];
    end
    if do_save
        parent_dir = fileparts(save_stem_path);
        if ~isempty(parent_dir) && ~exist(parent_dir, 'dir')
            try
                mkdir(parent_dir);
            catch me_2
                if ~isempty(mkdir_record_failure_tag)
                    run_warn_state = output_io_warn_utils.record_output_io_failure( ...
                        run_warn_state, mkdir_record_failure_tag, parent_dir, me_2, phase_tag);
                end
                if do_warn
                    run_warn_state = run_warn_state_utils.emit_softwarn_each_time_with_phase( ...
                        run_warn_state, phase_tag, 'CerUPP:Plot:SaveOutputDirCreateFailed', ...
                        'Failed to create figure output directory "%s": %s', ...
                        parent_dir, me_2.message);
                else
                    run_warn_state = plot_utils_record_suppressed_export_warning_local( ...
                        run_warn_state, phase_tag, ...
                        'CerUPP:Plot:SaveOutputDirCreateFailed', ...
                        'Failed to create figure output directory "%s": %s', ...
                        parent_dir, me_2.message);
                end
                plot_utils_close_figure_if_needed_local(fig_handle, close_after_save);
                return;
            end
        end
    end
    if save_outputs_as_fig
        fig_path = [char(save_stem_path) '.fig'];
        try
            savefig(fig_handle, fig_path);
        catch me_2
            if ~isempty(fig_record_failure_tag)
                run_warn_state = output_io_warn_utils.record_output_io_failure( ...
                    run_warn_state, fig_record_failure_tag, fig_path, me_2, phase_tag);
            end
            if do_warn
                run_warn_state = run_warn_state_utils.emit_softwarn_each_time_with_phase( ...
                    run_warn_state, phase_tag, savefig_warn_id, savefig_warn_fmt, ...
                    fig_path, me_2.message);
            else
                run_warn_state = plot_utils_record_suppressed_export_warning_local( ...
                    run_warn_state, phase_tag, savefig_warn_id, savefig_warn_fmt, ...
                    fig_path, me_2.message);
            end
        end
    end
    if save_outputs_as_png
        png_path = [char(save_stem_path) '.png'];
        png_status = plot_utils_save_png_with_fallback_backend_impl(fig_handle, png_path, export_args{:});
        run_warn_state = output_io_warn_utils.handle_png_export_status( ...
            run_warn_state, png_status, png_path, phase_tag, ...
            png_warn_key, png_warn_id, record_failure_tag, do_warn);
    end
    plot_utils_close_figure_if_needed_local(fig_handle, close_after_save);
end

function run_warn_state = plot_utils_record_suppressed_export_warning_local( ...
        run_warn_state, phase_tag, warn_id, msg_fmt, varargin)
% Record an export failure in warning_phase without emitting visible warning text.

    warn_id = char(string(warn_id));
    msg_fmt = char(string(msg_fmt));
    try
        msg_txt = sprintf(msg_fmt, varargin{:});
    catch me_fmt
        msg_txt = sprintf('[format_failed:%s] %s', char(string(me_fmt.identifier)), msg_fmt);
    end
    run_warn_state = run_warn_state_utils.record_warning_phase_event( ...
        run_warn_state, phase_tag, warn_id, msg_txt, 'direct_record');
end

function tf = plot_utils_has_named_option_local(plot_args, option_names)
% Return true when a Name/Value list already contains any option_names entry.

    tf = false;
    if isempty(plot_args) || isempty(option_names)
        return;
    end
    if ischar(option_names) || (isstring(option_names) && isscalar(option_names))
        option_names = {char(option_names)};
    else
        option_names = cellfun(@char, cellstr(string(option_names(:).')), 'UniformOutput', false);
    end
    for ii = 1:2:(numel(plot_args) - 1)
        key = plot_args{ii};
        if isstring(key) && isscalar(key)
            key = char(key);
        end
        if ischar(key) && any(strcmpi(strtrim(key), option_names))
            tf = true;
            return;
        end
    end
end

function plot_utils_close_figure_if_needed_local(fig_handle, close_figure_now)
% Shared close-if-valid shell for the main plotting helpers.

    if close_figure_now && ~isempty(fig_handle) && isgraphics(fig_handle)
        close(fig_handle);
    end
end
