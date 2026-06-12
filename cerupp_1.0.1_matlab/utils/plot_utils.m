classdef plot_utils
%PLOT_UTILS Consolidated plotting renderers.
% Purpose:
% - Keep the shared user-facing plotting entry points together.
% Shape-specific wrappers, sanitation helpers, session lifecycle, option
% parsing, export routing, and shared diagnostic helpers live in
% plot_support_utils.
% Called mainly from cerupp_section6a_postprocess.m and other end-of-run plot callers.

    methods (Static)
        function varargout = make_plot(x_data, y_data, z_data, legend_text, title_text, ...
                x_label, y_label, save_name, plot_settings, varargin)
        %MAKE_PLOT Generic plotting wrapper with explicit positional inputs.
        % Accepted public call shapes are:
        % - line: make_plot(x, [], z, legend_text, title_text, x_label, y_label, save_name, plot_settings, ...)
        % - multi-line: make_plot(x, [], Z, legend_text, title_text, x_label, y_label, save_name, plot_settings, ...)
        % - surface/heatmap: make_plot(x_or_X, y_or_Y, Z, [], title_text, x_label, y_label, save_name, plot_settings, ...)
        % The public plot contract uses one canonical plot_settings struct
        % after save_name. Warning/export state stays on the explicit
        % trailing Name/Value surface.

            [varargout{1:nargout}] = plot_utils_make_plot_impl( ...
                x_data, y_data, z_data, legend_text, title_text, ...
                x_label, y_label, save_name, plot_settings, varargin{:});
        end

        function varargout = make_isosurface_plot(x_vals, y_vals, z_vals, volume_data, ...
                cut_position, title_text, x_label, y_label, z_label, save_name, ...
                plot_settings, varargin)
        %MAKE_ISOSURFACE_PLOT Public 3D isosurface plot entry point.
        % Ordinary call form is [ok, naninfo, info_nf, run_warn_state] =
        % make_isosurface_plot(x_vals, y_vals, z_vals, volume_data,
        % cut_position, title_text, x_label, y_label, z_label, save_name,
        % plot_settings, ...).
        % The public plot contract uses one canonical plot_settings struct
        % after save_name. Warning/export state stays on the explicit
        % trailing Name/Value surface.

            [varargout{1:nargout}] = plot_utils_make_isosurface_plot_impl( ...
                x_vals, y_vals, z_vals, volume_data, cut_position, ...
                title_text, x_label, y_label, z_label, save_name, ...
                plot_settings, varargin{:});
        end

        function varargout = make_scatter3_plot(x_vals, y_vals, z_vals, c_vals, title_text, ...
                x_label, y_label, z_label, save_name, plot_settings, varargin)
        %MAKE_SCATTER3_PLOT Public 3D scatter plot entry point.
        % Ordinary call form is run_warn_state =
        % make_scatter3_plot(x_vals, y_vals, z_vals, c_vals, title_text,
        % x_label, y_label, z_label, save_name, plot_settings, ...).
        % The public plot contract uses one canonical plot_settings struct
        % after save_name. Warning/export state stays on the explicit
        % trailing Name/Value surface.

            [varargout{1:nargout}] = plot_utils_make_scatter3_plot_impl( ...
                x_vals, y_vals, z_vals, c_vals, title_text, ...
                x_label, y_label, z_label, save_name, plot_settings, varargin{:});
        end

        function run_warn_state = run_initial_setup_plots(initial_plot_state)
        % Own the optional setup-only IC plots from Section 3C.

            run_warn_state = plot_utils_run_initial_setup_plots_local(initial_plot_state);
        end
    end

    methods (Static, Hidden)
        function varargout = sanitize_nonfinite_diag(varargin)
        %SANITIZE_NONFINITE_DIAG Generic plot/diagnostic sanitation helper.

            [varargout{1:nargout}] = plot_utils_sanitize_nonfinite_diag_impl(varargin{:});
        end

        function varargout = scan_diag_values(varargin)
        %SCAN_DIAG_VALUES Shared nonfinite/overflow/complex-leak scan helper for diagnostics.

            [varargout{1:nargout}] = plot_utils_scan_diag_values_local(varargin{:});
        end
    end
end

function run_warn_state = plot_utils_run_initial_setup_plots_local(initial_plot_state)
% Own the optional setup-only IC plots.
% Edit the visible Section 1 and Section 3 knobs plus make_initial_plots_flag
% in cerupp.m first. This helper only renders the initial-condition and
% setup diagnostics and returns the updated warning ledger.

    if nargin < 1 || ~isstruct(initial_plot_state) || ~isscalar(initial_plot_state)
        error('CerUPP:InvalidInitialSetupPlotInputs', ...
            'run_initial_setup_plots requires one scalar initial_plot_state struct.');
    end
    [x, y, t, A_xy, center_i, n_omega_fund_xy, n_ratio_diag_xy, ...
        freq_offset, initial_plot_settings, lambda_window, n_sell, ...
        propagation_medium_name, omega_window, c, run_warn_state] = ...
        struct_utils.unpack_struct_fields( ...
            initial_plot_state, ...
            {'x', 'y', 't', 'A_xy', 'center_i', 'n_omega_fund_xy', ...
             'n_ratio_diag_xy', 'freq_offset', 'initial_plot_settings', ...
             'lambda_window', 'n_sell', 'propagation_medium_name', ...
             'omega_window', 'c', 'run_warn_state'}, ...
            'initial_plot_state');

    initial_plot_phase_tag = 'setup';
    initial_plot_record_failure_tag = 'png_export';

    [~, ~, ~, run_warn_state] = plot_utils.make_plot( ...
        x/1e-6, y/1e-6, n_omega_fund_xy.', [], ...
        'Refractive Index Profile at omega_fund', ...
        'X [um]', 'Y [um]', ...
        'refractive_index_profile_fund', ...
        initial_plot_settings, ...
        'cbar_label', 'n(omega_fund) [dimensionless]', ...
        'run_warn_state', run_warn_state, ...
        'phase_tag', initial_plot_phase_tag, ...
        'record_failure_tag', initial_plot_record_failure_tag);

    [~, ~, ~, run_warn_state] = plot_utils.make_plot( ...
        t/1e-12, [], center_i, '', ...
        'IC on-axis intensity |A_S(x~0,y~0,t)|^2 (pulse-frame time)', ...
        't [ps] (pulse-frame)', 'Intensity [W/m^2]', ...
        'temporal_ic_profile', ...
        initial_plot_settings, ...
        'run_warn_state', run_warn_state, ...
        'phase_tag', initial_plot_phase_tag, ...
        'record_failure_tag', initial_plot_record_failure_tag);

    fluence_ic = trapz(t, n_ratio_diag_xy .* real(A_xy .* conj(A_xy)), 3);
    [~, ~, ~, run_warn_state] = plot_utils.make_plot( ...
        x/1e-6, y/1e-6, fluence_ic.', [], ...
        'Transverse fluence (IC) [J/m^2]', ...
        'x [um]', 'y [um]', ...
        'fluence_ic', ...
        initial_plot_settings, ...
        'cbar_label', 'Fluence [J/m^2]', ...
        'run_warn_state', run_warn_state, ...
        'phase_tag', initial_plot_phase_tag, ...
        'record_failure_tag', initial_plot_record_failure_tag);

    l1_amp_time_ic = trapz(t, abs(A_xy), 3);
    [~, ~, ~, run_warn_state] = plot_utils.make_plot( ...
        x/1e-6, y/1e-6, l1_amp_time_ic.', [], ...
        'Qualitative IC amplitude diagnostic: \int |A_S| dt [sqrt(W/m^2)*s] over pulse-frame time', ...
        'x [um]', 'y [um]', ...
        'l1_amp_time_ic', ...
        initial_plot_settings, ...
        'cbar_label', '\int |A_S| dt [sqrt(W/m^2)*s]', ...
        'run_warn_state', run_warn_state, ...
        'phase_tag', initial_plot_phase_tag, ...
        'record_failure_tag', initial_plot_record_failure_tag);

    [~, ~, ~, run_warn_state] = plot_utils.make_plot( ...
        (1:numel(freq_offset)).', [], ...
        freq_offset(:)/(2*pi)/1e12, '', ...
        'FFT detuning \Omega/(2\pi) [ifftshifted order]; physical \omega=\omega_{ref}-\Omega', ...
        'Array index (ifftshifted FFT order)', '\Omega/(2\pi) [THz]', ...
        'freq_offset', initial_plot_settings, ...
        'run_warn_state', run_warn_state, ...
        'phase_tag', initial_plot_phase_tag, ...
        'record_failure_tag', initial_plot_record_failure_tag);

    lambda_nm_plot = lambda_window(:) * 1e9;
    [lambda_nm_plot, idx_lam_plot] = sort(lambda_nm_plot, 'ascend');
    n_plot = n_sell(:);
    n_plot = n_plot(idx_lam_plot);
    sellmeier_plot_title = 'Sellmeier index vs wavelength';
    sellmeier_fit_range_nm = [];
    sellmeier_fit_label = '';
    if strcmpi(propagation_medium_name, 'AIR')
        sellmeier_fit_range_nm = [200, 2000];
        sellmeier_fit_label = 'dry-air fit edges 200-2000 nm';
    elseif strcmpi(propagation_medium_name, 'YAG')
        sellmeier_fit_range_nm = [400, 5000];
        sellmeier_fit_label = 'Zelmon fit edges 400-5000 nm';
    end
    if ~isempty(sellmeier_fit_range_nm)
        lambda_out_of_range = (lambda_nm_plot < sellmeier_fit_range_nm(1)) | ...
            (lambda_nm_plot > sellmeier_fit_range_nm(2));
        if any(lambda_out_of_range)
            sellmeier_plot_title = sprintf( ...
                'Sellmeier index vs wavelength (out-of-range wavelengths clamp to the %s)', ...
                sellmeier_fit_label);
        end
    end
    [~, ~, ~, run_warn_state] = plot_utils.make_plot( ...
        lambda_nm_plot, [], n_plot, '', ...
        sellmeier_plot_title, ...
        'Vacuum wavelength [nm]', 'Sellmeier index n(lambda)', ...
        'n_sell', initial_plot_settings, ...
        'run_warn_state', run_warn_state, ...
        'phase_tag', initial_plot_phase_tag, ...
        'record_failure_tag', initial_plot_record_failure_tag);

    try
        if numel(omega_window) == numel(n_sell)
            omega_vec_fft = omega_window(:);
            n_vec_fft = n_sell(:);
            [omega_sorted, idx_w] = sort(omega_vec_fft, 'ascend');
            n_vec_sorted = n_vec_fft(idx_w);
            k_vec_sorted = n_vec_sorted .* omega_sorted ./ c;

            eta1 = gradient(k_vec_sorted, omega_sorted);
            eta2 = gradient(eta1, omega_sorted);

            lambda_nm_local = (2*pi*c ./ omega_sorted) * 1e9;
            [lam_sorted, idx] = sort(lambda_nm_local, 'ascend');
            ng = c * eta1;
            eta2_fs2_per_mm = eta2 * 1e30 / 1e3;

            [~, ~, ~, run_warn_state] = plot_utils.make_plot( ...
                lam_sorted, [], ng(idx), '', ...
                'Grid-sampled group index n_g on current \omega window', ...
                'Vacuum wavelength [nm]', 'n_g', ...
                'dispersion_group_index', ...
                initial_plot_settings, ...
                'run_warn_state', run_warn_state, ...
                'phase_tag', initial_plot_phase_tag, ...
                'record_failure_tag', initial_plot_record_failure_tag);

            [~, ~, ~, run_warn_state] = plot_utils.make_plot( ...
                lam_sorted, [], eta2_fs2_per_mm(idx), '', ...
                'Grid-sampled \beta_2 (\eta_2, GVD) on current \omega window', ...
                'Vacuum wavelength [nm]', 'beta2 [fs^2/mm]', ...
                'dispersion_beta2', ...
                initial_plot_settings, ...
                'run_warn_state', run_warn_state, ...
                'phase_tag', initial_plot_phase_tag, ...
                'record_failure_tag', initial_plot_record_failure_tag);
        else
            run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                run_warn_state, initial_plot_phase_tag, ...
                'setup_dispersion_plots_skipped', ...
                'CerUPP:DispersionPlotsSkipped', ...
                'dispersion plots skipped: omega_window/n_sell size mismatch or missing vars.');
        end
    catch me_2
        run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
            run_warn_state, initial_plot_phase_tag, ...
            'setup_dispersion_plots_failed', ...
            'CerUPP:DispersionPlotsFailed', ...
            'dispersion plots failed: %s', me_2.message);
    end
end

function [x_2, naninfo, info, run_warn_state] = plot_utils_sanitize_nonfinite_diag_impl(x_2, label, arg3, cap_hi, treat_nan_as_blowup)
% Generic plot/diagnostic sanitation helper owned by plot_utils.
% ARG3 accepts either an existing naninfo state or an opts struct. The
% supported opts fields are naninfo, count_only,
% replace_nonfinite_with_nan, cap_value, treat_nan_as_blowup,
% warn, and warn_id.
% Returns the possibly adjusted array, accumulated naninfo, and an
% info struct summarizing the applied policy and detected counts.

    opts = struct();
    naninfo = struct('label', {}, 'n_nan', {}, 'n_cap', {}, 'cap_hi', {});
    if nargin >= 3 && ~isempty(arg3)
        if isstruct(arg3) && isscalar(arg3)
            opts = arg3;
            if isfield(opts, 'naninfo') && ~isempty(opts.naninfo)
                naninfo = opts.naninfo;
            end
        else
            naninfo = arg3;
        end
    end

    replace_nonfinite_with_nan = false;
    if isfield(opts, 'replace_nonfinite_with_nan') && ~isempty(opts.replace_nonfinite_with_nan)
        replace_nonfinite_with_nan = logical(opts.replace_nonfinite_with_nan);
    end
    count_only = false;
    if isfield(opts, 'count_only') && ~isempty(opts.count_only)
        count_only = logical(opts.count_only);
    end
    if isfield(opts, 'fast_assume_finite') && ~isempty(opts.fast_assume_finite)
        error('plot_utils:UnsupportedFastAssumeFinite', ...
            ['opts.fast_assume_finite is no longer supported because it did not preserve ', ...
             'the standard sanitize_nonfinite_diag return contract.']);
    end

    if nargin < 4 || isempty(cap_hi)
        cap_hi = 1e120;
    end
    if isfield(opts, 'cap_value') && ~isempty(opts.cap_value)
        cap_hi = opts.cap_value;
    end
    cap_hi = plot_utils_sanitize_cap_for_array_class_local(cap_hi, x_2);

    if nargin < 5 || isempty(treat_nan_as_blowup)
        treat_nan_as_blowup = false;
    end
    if isfield(opts, 'treat_nan_as_blowup') && ~isempty(opts.treat_nan_as_blowup)
        treat_nan_as_blowup = logical(opts.treat_nan_as_blowup);
    end

    do_warn = true;
    if isfield(opts, 'warn') && ~isempty(opts.warn)
        do_warn = logical(opts.warn);
    end
    [run_warn_state, phase_tag] = plot_utils_extract_warn_state_from_opts_local(opts);
    warn_id_override = '';
    if isfield(opts, 'warn_id') && ~isempty(opts.warn_id)
        warn_id_override = char(string(opts.warn_id));
    end

    diag_scan = plot_utils_scan_diag_values_local(x_2, cap_hi, false);
    nan_mask = diag_scan.nan_mask;
    blow_mask = diag_scan.blow_mask;
    n_nan = diag_scan.n_nan;
    n_cap = diag_scan.n_cap;
    if treat_nan_as_blowup && n_nan > 0
        blow_mask = blow_mask | nan_mask;
        n_cap = nnz(blow_mask);
        nan_mask(:) = false;
        n_nan = 0;
    end

    n_replaced = 0;
    if count_only
        if do_warn && (n_cap > 0 || n_nan > 0)
            warn_id = warn_id_override;
            if isempty(warn_id)
                warn_id = 'CerUPP:Diagnostics:NonFiniteDetected';
            end
            run_warn_state = plot_utils_emit_softwarn_local( ...
                run_warn_state, phase_tag, do_warn, warn_id, ...
                '%s: detected %d Inf/huge and %d NaN values (no modification).', ...
                label, n_cap, n_nan);
        end
    elseif replace_nonfinite_with_nan
        rep_mask = blow_mask | nan_mask;
        n_replaced = nnz(rep_mask);
        if n_replaced > 0
            x_2(rep_mask) = NaN;
            if do_warn
                warn_id = warn_id_override;
                if isempty(warn_id)
                    warn_id = 'CerUPP:Diagnostics:NonFiniteReplaced';
                end
                run_warn_state = plot_utils_emit_softwarn_local( ...
                    run_warn_state, phase_tag, do_warn, warn_id, ...
                    '%s: %d non-finite values replaced by NaN (diagnostic/plot only).', ...
                    label, n_replaced);
            end
        end
    else
        if n_cap > 0
            s = sign(real(x_2(blow_mask)));
            s(~isfinite(s) | (s == 0)) = 1;
            x_2(blow_mask) = cast(cap_hi .* s, 'like', x_2);
            n_replaced = n_cap;
            if do_warn
                warn_id = warn_id_override;
                if isempty(warn_id)
                    warn_id = 'CerUPP:Diagnostics:NonFiniteCap';
                end
                run_warn_state = plot_utils_emit_softwarn_local( ...
                    run_warn_state, phase_tag, do_warn, warn_id, ...
                    '%s: %d non-finite/huge values capped to +/-%.3g preserving sign.', ...
                    label, n_cap, cap_hi);
            end
        end
        if n_nan > 0 && do_warn
            warn_id = warn_id_override;
            if isempty(warn_id)
                warn_id = 'CerUPP:Diagnostics:NonFiniteNaN';
            end
            run_warn_state = plot_utils_emit_softwarn_local( ...
                run_warn_state, phase_tag, do_warn, warn_id, ...
                '%s: %d NaNs left as NaN.', label, n_nan);
        end
    end

    if (n_nan > 0) || (n_cap > 0)
        naninfo(end+1) = struct('label', label, 'n_nan', n_nan, 'n_cap', n_cap, 'cap_hi', cap_hi);
    end

    info = struct( ...
        'label', label, ...
        'n_nan', n_nan, ...
        'n_cap', n_cap, ...
        'n_replaced', n_replaced, ...
        'cap_hi', cap_hi, ...
        'replace_nonfinite_with_nan', replace_nonfinite_with_nan, ...
        'count_only', count_only, ...
        'had_issue', (n_nan > 0) || (n_cap > 0));
    info.run_warn_state = run_warn_state;
end

function [run_warn_state, phase_tag] = plot_utils_extract_warn_state_from_opts_local(opts)
% Pull one explicit run warning context from plot/diagnostic opts.

    if nargin < 1 || isempty(opts) || ~isstruct(opts)
        opts = struct();
    end
    run_warn_state = struct_utils.opt_struct_field(opts, 'run_warn_state', struct());
    phase_tag = struct_utils.opt_struct_field(opts, 'phase_tag', run_warn_state_utils.phase_end());
    if ~isstruct(run_warn_state)
        error('plot_utils:InvalidRunWarnState', ...
            'opts.run_warn_state must be a scalar struct when provided.');
    end
    run_warn_state = struct_utils.ensure_warned_keys_map(run_warn_state);
    phase_tag = run_warn_state_utils.canonical_phase_name(phase_tag);
end

function run_warn_state = plot_utils_emit_softwarn_local( ...
        run_warn_state, phase_tag, do_warn, canon_id, msg_fmt, varargin)
% Route one plot/diagnostic warning through the run-owned warning ledger.

    if nargin < 3 || ~logical(do_warn)
        return;
    end
    run_warn_state = run_warn_state_utils.emit_softwarn_each_time_with_phase( ...
        run_warn_state, phase_tag, canon_id, msg_fmt, varargin{:});
end

function label = plot_utils_resolve_diag_label_local(save_name, title_text, fallback_label)
% Prefer a user-facing plot identifier in sanitation warnings.

    label = strtrim(char(string(fallback_label)));
    if nargin >= 1 && ~isempty(save_name)
        save_name = strtrim(char(string(save_name)));
        if ~isempty(save_name)
            label = save_name;
            return;
        end
    end
    if nargin >= 2 && ~isempty(title_text)
        title_text = strtrim(char(string(title_text)));
        if ~isempty(title_text)
            label = title_text;
        end
    end
end

function [session, renderer_opts, run_warn_state, phase_tag, do_warn, plot_args] = ...
        plot_utils_begin_renderer_session( ...
        save_name, plot_settings, option_specs, varargin)
% Shared session/bootstrap path for the concrete plot renderers below.

    plot_settings = plot_support_utils.normalize_public_plot_settings(plot_settings);
    plot_settings_args = { ...
        'outdir', plot_settings.outdir, ...
        'warn', plot_settings.warn, ...
        'visible', plot_settings.visible};
    if isfield(plot_settings, 'close_figure') && ~isempty(plot_settings.close_figure)
        plot_settings_args = [plot_settings_args, {'close_figure', plot_settings.close_figure}];
    end
    if plot_utils_option_specs_include_field_local(option_specs, 'surface_shading_mode')
        plot_settings_args = [plot_settings_args, ...
            {'surface_shading', plot_settings.surface_shading_mode}];
    end
    [varargin, run_warn_state, phase_tag, record_failure_tag] = ...
        plot_support_utils.consume_export_state_options(varargin, 'png_export');
    [session, renderer_opts] = plot_support_utils.begin_main_plot( ...
        save_name, plot_settings.save_outputs_as_fig, ...
        plot_settings.save_outputs_as_png, option_specs, ...
        plot_settings_args{:}, varargin{:});
    session.phase_tag = phase_tag;
    session.record_failure_tag = record_failure_tag;
    do_warn = session.do_warn;
    plot_args = session.plot_args;
end

function [ok, naninfo, info_nf, run_warn_state] = plot_utils_make_plot_impl(x_data, y_data, z_data, legend_text, title_text, ...
x_label, y_label, save_name, plot_settings, varargin)
% Implementation for plot_utils.make_plot.
% The public wrapper owns the caller-facing positional and Name/Value
% contract. This body only selects the render branch:
% - line: vector z_data with explicit x_data
% - multi-series: matrix z_data with empty y_data
% - surface/heatmap: 2D z_data with surf-compatible axes or grids
% Surface shading is an explicit plot option and is visual only;
% underlying z_data is unchanged.
% naninfo/info_nf collect the local nonfinite sanitation results.

ok = false;
naninfo = struct('label', {}, 'n_nan', {}, 'n_cap', {}, 'cap_hi', {});
info_nf = struct();
[session, main_plot_opts, run_warn_state, phase_tag, do_warn, plot_args] = ...
    plot_utils_begin_renderer_session( ...
    save_name, plot_settings, ...
    [ ...
        struct('field', 'treat_nan_as_blowup', 'names', {{'treat_nan_as_blowup'}}, 'parse_fn', @plot_support_utils.parse_bool_like, 'default_value', false), ...
        struct('field', 'multiline_specs_bundle', 'names', {{'multi_line_specs', 'series_line_specs'}}, 'parse_fn', @plot_support_utils.parse_multiline_specs_option, 'default_value', struct('specs', {{}}, 'apply_all', false)), ...
        struct('field', 'cbar_label', 'names', {{'cbar_label'}}, 'parse_fn', @plot_support_utils.parse_char_scalar, 'default_value', ''), ...
        struct('field', 'replace_nonfinite_with_nan', 'names', {{'replace_nonfinite_with_nan'}}, 'parse_fn', @plot_support_utils.parse_bool_like, 'default_value', true), ...
        struct('field', 'skip_nonfinite_scan', 'names', {{'skip_nonfinite_scan'}}, 'parse_fn', @plot_support_utils.parse_bool_like, 'default_value', false), ...
        struct('field', 'surface_shading_mode', 'names', {{'surface_shading', 'shading_mode'}}, 'parse_fn', @plot_support_utils.parse_surface_shading_mode, 'default_value', 'interp') ...
    ], varargin{:});
save_name_new = session.save_name_new;
visible_now = session.visible_now;

treat_nan_as_blowup_plot = false;
multi_line_specs = {};
multi_line_specs_apply_to_all = false;
replace_nonfinite_with_nan_plot = true;
skip_nonfinite_scan = false;
cbar_label = '';
surface_shading_mode = 'interp';
treat_nan_as_blowup_plot = main_plot_opts.treat_nan_as_blowup;
multi_line_specs = main_plot_opts.multiline_specs_bundle.specs;
multi_line_specs_apply_to_all = main_plot_opts.multiline_specs_bundle.apply_all;
cbar_label = main_plot_opts.cbar_label;
replace_nonfinite_with_nan_plot = main_plot_opts.replace_nonfinite_with_nan;
skip_nonfinite_scan = main_plot_opts.skip_nonfinite_scan;
surface_shading_mode = main_plot_opts.surface_shading_mode;

if isempty(save_name_new)
    if do_warn && (plot_settings.save_outputs_as_fig || plot_settings.save_outputs_as_png)
        run_warn_state = plot_utils_emit_softwarn_local( ...
            run_warn_state, phase_tag, do_warn, 'CerUPP:Plot:EmptySaveName', ...
            'make_plot: save_name "%s" has no base filename; skipping save.', char(save_name));
    end
end

% Begin plotting
fig_handle = [];
ax_handle = [];
try
% Plot sanitation policy:
% - non-finite / huge values are masked by default so a local blowup does
%   not flatten the whole figure.
% - callers may opt out with replace_nonfinite_with_nan=false when capped
%   plotting is truly desired.

opts_nf = struct( ...
    'warn', do_warn, ...
    'warn_id', 'CerUPP:Plot:NonFiniteHandled', ...
    'cap_value', 1e120, ...
    'treat_nan_as_blowup', treat_nan_as_blowup_plot, ...
    'replace_nonfinite_with_nan', replace_nonfinite_with_nan_plot);
if skip_nonfinite_scan
    z_plot = z_data;
    naninfo = [];
    info_nf = struct('had_issue', false, 'n_nan', 0, 'n_cap', 0);
else
    diag_label = plot_utils_resolve_diag_label_local( ...
        save_name_new, title_text, 'make_plot:z_data');
    [z_plot, naninfo, info_nf, run_warn_state] = plot_utils.sanitize_nonfinite_diag( ...
        z_data, diag_label, opts_nf);
end

if isvector(z_plot)
    % --- Line plot case (single series) ---
    % Sort by x ascending before plotting; varargin applies here only.
    % Degenerate one-plane surface/heatmap callers may still arrive here
    % with one stored x/z plane and a live second-axis vector in y_data.
    % In that narrow case, reuse y_data as the line x-axis instead of
    % hard-failing the reduced single-plane plot.

    zv = z_plot(:);
    xv = x_data(:);
    line_x_label = x_label;
    line_y_label = y_label;
    line_cbar_label = cbar_label;
    if ~isempty(y_data)
        yv = y_data(:);
        if ((numel(xv) <= 1) || isempty(xv)) && (numel(yv) == numel(zv))
            xv = yv;
            line_x_label = y_label;
            if ~isempty(cbar_label)
                line_y_label = cbar_label;
            end
            line_cbar_label = '';
        else
            error('plot_utils:IgnoredYDataInLineMode', ...
                ['Single-line make_plot calls do not consume y_data. ', ...
                 'Pass y_data=[].']);
        end
    end
    if isempty(xv)
        error('make_plot:EmptyLineXAxis', ...
            'Line plot requires explicit nonempty x_data; x_data was empty for numel(z_data)=%d.', ...
            numel(zv));
    elseif numel(xv) ~= numel(zv)
        error('make_plot:LineSizeMismatch', ...
            'Line plot requires numel(x_data)==numel(z_data). numel(x_data)=%d, numel(z_data)=%d', ...
            numel(xv), numel(zv));
    end
    if issorted(xv, 'ascend')
        xv_sorted = xv;
        zv_sorted = zv;
    else
        [xv_sorted, idx] = sort(xv, 'ascend');  % NaNs sort to end
        zv_sorted = zv(idx);
    end
    [legend_text_disp, title_text_disp, x_label_disp, y_label_disp, cbar_label_disp] = ...
        plot_utils_sanitize_main_plot_labels_local( ...
            legend_text, title_text, line_x_label, line_y_label, line_cbar_label);
    [fig_handle, ax_handle] = plot_support_utils.open_figure(visible_now, false);
    % Support either a leading MATLAB line-spec token (e.g., 'bo-')
    % or standard Name/Value plotting properties.

    if ~isempty(plot_args) && (ischar(plot_args{1}) || (isstring(plot_args{1}) && isscalar(plot_args{1})))
        first_token = strtrim(char(plot_args{1}));
        is_line_spec = is_plot_linespec_token_local(first_token);
        if is_line_spec
            plot(ax_handle, xv_sorted, zv_sorted, first_token, 'LineWidth', 2, plot_args{2:end});
        else
            plot(ax_handle, xv_sorted, zv_sorted, 'LineWidth', 2, plot_args{:});
        end
    else
        plot(ax_handle, xv_sorted, zv_sorted, 'LineWidth', 2, plot_args{:});
    end
    if ~isempty(legend_text_disp)
        legend(ax_handle, legend_text_disp, 'Interpreter', 'none');
    end
elseif ismatrix(z_plot) && (isempty(y_data) || numel(y_data)==0) && isvector(x_data)
    % --- Line plot case (multiple series) ---

    xv = x_data(:);
    z = z_plot;
    if isempty(xv)
        error('make_plot:EmptyMultiLineXAxis', ...
            ['Multi-line plot requires explicit nonempty x_data; x_data was empty for ', ...
             'size(z_data)=%s.'], ...
            mat2str(size(z_plot)));
    end
    if size(z,1) ~= numel(xv)
        error('make_plot:MultiLineSizeMismatch', ...
            ['For multi-line plot, size(z_data,1) must equal numel(x_data); ', ...
             'automatic orientation repair is not performed. size(z_data)=%s, numel(x_data)=%d'], ...
            mat2str(size(z_plot)), numel(xv));
    end
    if issorted(xv, 'ascend')
        xv_sorted = xv;
        zs = z;
    else
        [xv_sorted, idx] = sort(xv, 'ascend');
        zs = z(idx, :);
    end
    [legend_text_disp, title_text_disp, x_label_disp, y_label_disp, cbar_label_disp] = ...
        plot_utils_sanitize_main_plot_labels_local(legend_text, title_text, x_label, y_label, cbar_label);
    n_series = size(zs,2);
    line_specs_use = build_multiline_specs_local( ...
        n_series, multi_line_specs, multi_line_specs_apply_to_all);
    [fig_handle, ax_handle] = plot_support_utils.open_figure(visible_now, false);
    hold(ax_handle, 'on');
    for jj = 1:n_series
        spec_jj = line_specs_use{jj};
        if isempty(spec_jj)
            plot(ax_handle, xv_sorted, zs(:,jj), 'LineWidth', 2, plot_args{:});
        else
            plot(ax_handle, xv_sorted, zs(:,jj), spec_jj, 'LineWidth', 2, plot_args{:});
        end
    end
    hold(ax_handle, 'off');
    if ~isempty(legend_text_disp)
        legend(ax_handle, legend_text_disp, 'Interpreter', 'none');
    end
else
    % --- Surface plot case ---
    % x_data/y_data may be vectors (meshgrid implied) or 2D grids; sizes must match z_data.

    if ~plot_support_utils.optional_positional_arg_is_empty(legend_text)
        error('plot_utils:IgnoredLegendTextInSurfaceMode', ...
            'Surface/heatmap make_plot calls do not consume legend_text; pass [] or "" in that slot.');
    end
    plot_utils_assert_surface_shape_local(x_data, y_data, z_plot);
    if ~isempty(plot_args) && (mod(numel(plot_args), 2) ~= 0)
        error('CerUPP:PlotArgsOddLength', ...
            'Surface-mode plot_args in make_plot must be Name/Value pairs (even count). Got %d args.', ...
            numel(plot_args));
    end
    [legend_text_disp, title_text_disp, x_label_disp, y_label_disp, cbar_label_disp] = ...
        plot_utils_sanitize_main_plot_labels_local(legend_text, title_text, x_label, y_label, cbar_label);
    [fig_handle, ax_handle] = plot_support_utils.open_figure(visible_now, false);
    surf_handle = surf(ax_handle, x_data, y_data, z_plot, 'EdgeColor', 'none'); % heatmap-like
    shading(ax_handle, surface_shading_mode); % visual only; does not resample underlying z_data
    if ~isempty(plot_args)
        set(surf_handle, plot_args{:});
    end
    view(ax_handle, 0, 90);     % top-down 2D projection
    set(ax_handle, 'YDir', 'normal'); % deterministic image-like orientation
    axis(ax_handle, 'tight');
    % Keep nonuniform physical axes readable in x/z or y/z projections:
    % do not force equal-to-scale aspect in multi-scale plots.

    set(ax_handle, 'DataAspectRatioMode', 'auto');
    cb = colorbar(ax_handle);  % show intensity scale
    if ~isempty(strtrim(cbar_label_disp))
        ylabel(cb, cbar_label_disp, 'Interpreter', 'none');
    end
end

% Axis and title labels
xlabel(ax_handle, x_label_disp, 'Interpreter', 'none'); 
ylabel(ax_handle, y_label_disp, 'Interpreter', 'none');
title(ax_handle, title_text_disp, 'Interpreter', 'none');

% --- Conditional saving ---
% save_name_new is a base; extensions are appended if requested.
run_warn_state = plot_support_utils.finalize_plot_success(fig_handle, session, run_warn_state);
ok = true;

catch me
plot_utils_rethrow_if_contract_error_local(me);
if do_warn || (nargout == 0)
    run_warn_state = plot_utils_emit_softwarn_local( ...
        run_warn_state, phase_tag, true, 'CerUPP:Plot:MakePlotFailed', ...
        'make_plot: plot "%s" failed (%s). Skipping this plot.', ...
        session.save_name_new, me.message);
end
plot_support_utils.finalize_plot_close(fig_handle, session);
ok = false;
end


end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Runtime internals: Diagnostics, logging & reporting
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [specs, apply_to_all, ok] = normalize_multiline_specs_local(val)
% Parse multi-line line-spec override input.
% Supported forms are [], row-char input, scalar string input, string
% arrays, char matrices, and cell arrays of row-char/string scalars.
% Scalar text input is normalized to one token and broadcast to all series
% by returning apply_to_all=true. Nonempty tokens must pass the
% MATLAB line-spec validator before they are used.

    specs = {};
    apply_to_all = false;
    ok = false;

    if isempty(val)
        ok = true;
        return;
    end

    if ischar(val)
        if isrow(val)
            specs = {strtrim(val)};
            apply_to_all = true;
            ok = true;
            return;
        end
        val = cellstr(val);
    elseif isstring(val)
        if isscalar(val)
            specs = {strtrim(char(val))};
            apply_to_all = true;
            ok = true;
            return;
        end
        val = cellstr(val(:));
    elseif iscell(val)
        val = val(:);
    else
        return;
    end

    specs = cell(numel(val), 1);
    for kk = 1:numel(val)
        tok = val{kk};
        if isstring(tok) && isscalar(tok)
            tok = char(tok);
        end
        if ~(ischar(tok) && isrow(tok))
            specs = {};
            return;
        end
        tok = strtrim(tok);
        if ~isempty(tok) && ~is_plot_linespec_token_local(tok)
            error('plot_utils:InvalidMultiLineSpec', ...
                'multi_line_specs entry %d ("%s") is not a valid MATLAB line-spec token.', ...
                kk, tok);
        end
        specs{kk} = tok;
    end
    ok = true;
end

function tf = is_plot_linespec_token_local(token)
% Return true for valid MATLAB line-spec token strings.

    if isstring(token) && isscalar(token)
        token = char(token);
    end
    tf = ischar(token) && isrow(token);
    if ~tf
        return;
    end
    token = strtrim(token);
    if isempty(token)
        tf = false;
        return;
    end

    remainder = token;
    saw_style = false;
    saw_marker = false;
    saw_color = false;
    style_tokens = {'--', '-.', ':', '-'};
    marker_chars = '+o*.xsd^v><ph|';
    color_chars = 'rgbcmykw';

    while ~isempty(remainder)
        matched = false;
        if ~saw_style
            for ii = 1:numel(style_tokens)
                style_tok = style_tokens{ii};
                if strncmp(remainder, style_tok, numel(style_tok))
                    remainder = remainder((numel(style_tok)+1):end);
                    saw_style = true;
                    matched = true;
                    break;
                end
            end
            if matched
                continue;
            end
        end

        ch = remainder(1);
        if ~saw_marker && any(ch == marker_chars)
            remainder = remainder(2:end);
            saw_marker = true;
            continue;
        end
        if ~saw_color && any(ch == color_chars)
            remainder = remainder(2:end);
            saw_color = true;
            continue;
        end
        tf = false;
        return;
    end
    tf = true;
end

function [legend_text_disp, title_text_disp, x_label_disp, y_label_disp, cbar_label_disp] = ...
        plot_utils_sanitize_main_plot_labels_local(legend_text, title_text, x_label, y_label, cbar_label)
% Normalize main make_plot labels only after the plot branch passes cheap validation.

[legend_text_disp, title_text_disp, x_label_disp, y_label_disp, cbar_label_disp] = ...
    plot_utils_sanitize_text_bundle_local(legend_text, title_text, x_label, y_label, cbar_label);
end

function varargout = plot_utils_sanitize_text_bundle_local(varargin)
% Normalize one or more label/title strings for Interpreter='none' rendering.

    varargout = cell(1, nargout);
    for ii = 1:nargout
        if ii <= nargin
            varargout{ii} = plot_support_utils.sanitize_text_for_none_interpreter(varargin{ii});
        else
            varargout{ii} = '';
        end
    end
end

function plot_utils_assert_surface_shape_local(x_data, y_data, z_plot)
% Cheap surface-shape validation before figure/text work in make_plot.

if isempty(z_plot) || ~ismatrix(z_plot)
    error('make_plot:SurfaceSizeMismatch', ...
        'Surface plot requires z_data to be a nonempty 2D matrix; got size %s.', ...
        mat2str(size(z_plot)));
end
z_sz = size(z_plot);
if isvector(x_data) && isvector(y_data)
    if ~(numel(x_data) == z_sz(2) && numel(y_data) == z_sz(1))
        error('make_plot:SurfaceSizeMismatch', ...
            ['Surface plot with vector axes requires numel(x_data)==size(z_data,2) and ', ...
             'numel(y_data)==size(z_data,1); got numel(x_data)=%d, numel(y_data)=%d, size(z_data)=%s.'], ...
            numel(x_data), numel(y_data), mat2str(z_sz));
    end
elseif ~(isequal(size(x_data), z_sz) && isequal(size(y_data), z_sz))
    error('make_plot:SurfaceSizeMismatch', ...
        ['Surface plot requires x_data and y_data to be vectors matching z_data dimensions or ', ...
         '2D grids with size(z_data). Got size(x_data)=%s, size(y_data)=%s, size(z_data)=%s.'], ...
        mat2str(size(x_data)), mat2str(size(y_data)), mat2str(z_sz));
end
end

function line_specs_use = build_multiline_specs_local(n_series, specs_override, apply_to_all)
% Build per-series line-spec tokens from one override path.
% Empty tokens preserve MATLAB's default line styling. When apply_to_all is
% true, the first override token is broadcast to all series; otherwise the
% helper overrides only the first min(n_series, numel(specs_override))
% series and leaves later tokens empty/default.

    line_specs_use = repmat({''}, 1, n_series);

    if isempty(specs_override)
        return;
    end

    if apply_to_all
        tok = specs_override{1};
        if ~isempty(tok)
            line_specs_use = repmat({tok}, 1, n_series);
        end
        return;
    end

    n_copy = min(n_series, numel(specs_override));
    for kk = 1:n_copy
        tok = specs_override{kk};
        if ~isempty(tok)
            line_specs_use{kk} = tok;
        end
    end
end

function [ok, naninfo, info_nf, run_warn_state] = plot_utils_make_isosurface_plot_impl(x_vals, y_vals, z_vals, volume_data, cut_position, ...
title_text, x_label, y_label, z_label, save_name, ...
plot_settings, varargin)
% Implementation for plot_utils.make_isosurface_plot.
% The public wrapper owns the positional and Name/Value contract. This
% body documents only the local voxel-layout and render choices:
% - volume_data is stored as [Nx Ny Nz] matching x_vals/y_vals/z_vals
% - large volumes may avoid permute(V,[2 1 3]) by using index-space
%   isosurface plus vertex remapping to physical axes
% - nonfinite values map to NaN by default unless treat_nan_as_blowup=true
% - ok/info_nf/naninfo capture local skip, fallback, and sanitation status

[session, iso_plot_opts, run_warn_state, phase_tag, do_warn, plot_args] = ...
    plot_utils_begin_renderer_session( ...
    save_name, plot_settings, ...
    [ ...
        struct('field', 'max_voxels', 'names', {{'max_voxels'}}, 'parse_fn', @plot_support_utils.parse_positive_integer, 'default_value', 8e6), ...
        struct('field', 'permute_voxels_threshold', 'names', {{'permute_voxels_threshold'}}, 'parse_fn', @plot_support_utils.parse_positive_integer, 'default_value', 2e6), ...
        struct('field', 'treat_nan_as_blowup', 'names', {{'treat_nan_as_blowup'}}, 'parse_fn', @plot_support_utils.parse_bool_like, 'default_value', false) ...
    ], varargin{:});

% Optional warning emission control:
% - warn=true (default): emit helper-local warnings.
% - warn=false: suppress helper warnings so caller can aggregate/report.
max_voxels = 8e6;
permute_voxels_threshold = 2e6;
treat_nan_as_blowup_iso = false;
max_voxels = iso_plot_opts.max_voxels;
permute_voxels_threshold = iso_plot_opts.permute_voxels_threshold;
treat_nan_as_blowup_iso = iso_plot_opts.treat_nan_as_blowup;
replace_nonfinite_with_nan_iso = ~treat_nan_as_blowup_iso;

if ~isempty(plot_args) && (mod(numel(plot_args), 2) ~= 0)
    error('CerUPP:PlotArgsOddLength', ...
        'Unparsed plot_args in make_isosurface_plot must be Name/Value pairs (even count). Got %d args.', ...
        numel(plot_args));
end


    % Begin plotting
    fig_handle = [];
    ok = false;
    naninfo = struct('label', {}, 'n_nan', {}, 'n_cap', {}, 'cap_hi', {});
    info_nf = struct( ...
        'isosurface_skip_reason', '', ...
        'isosurface_fallback_used', false, ...
        'isosurface_voxel_stride', 1, ...
        'isosurface_voxel_downsampled', false, ...
        'isosurface_scan_volume_n_nan', 0, ...
        'isosurface_scan_volume_n_cap', 0, ...
        'isosurface_full_volume_n_nan', 0, ...
        'isosurface_full_volume_n_cap', 0);

try
    % Ensure coordinate vectors match volume dimensions

    x_vals = x_vals(:);
    y_vals = y_vals(:);
    z_vals = z_vals(:);
    data_sz = size(volume_data);
    if numel(data_sz) ~= 3 || data_sz(1) ~= numel(x_vals) || data_sz(2) ~= numel(y_vals) || data_sz(3) ~= numel(z_vals)
        error('make_isosurface_plot:SizeMismatch', ...
            'volume_data must be [numel(x_vals) numel(y_vals) numel(z_vals)].');
    end
    % Keep Interpreter='none' and normalize TeX-like markup through one shared helper.

    [x_label_disp, y_label_disp, z_label_disp, title_text_disp] = ...
        plot_utils_sanitize_text_bundle_local(x_label, y_label, z_label, title_text);

    opts_nf = struct('warn', do_warn, 'cap_value', 1e120, ...
        'treat_nan_as_blowup', treat_nan_as_blowup_iso, ...
        'replace_nonfinite_with_nan', replace_nonfinite_with_nan_iso);

    n_total = numel(volume_data);
    n_vox = n_total;
    stride = 1;
    if isfinite(max_voxels) && (n_vox > max_voxels)
        stride = max(1, ceil((n_vox / max_voxels)^(1/3)));
    end

    x_use = x_vals;
    y_use = y_vals;
    z_use = z_vals;
    volume_use_raw = volume_data;
    if stride > 1
        ix = unique([1:stride:numel(x_vals), numel(x_vals)]);
        iy = unique([1:stride:numel(y_vals), numel(y_vals)]);
        iz = unique([1:stride:numel(z_vals), numel(z_vals)]);
        x_use = x_vals(ix);
        y_use = y_vals(iy);
        z_use = z_vals(iz);
        volume_use_raw = volume_data(ix, iy, iz);
        info_nf.isosurface_voxel_stride = double(stride);
        info_nf.isosurface_voxel_downsampled = true;
        if do_warn
            run_warn_state = plot_utils_emit_softwarn_local( ...
                run_warn_state, phase_tag, do_warn, 'CerUPP:Diagnostics:IsosurfaceDownsampled', ...
                ['Downsampling volume for isosurface plotting: stride=%d, voxels %d -> %d ', ...
                 '(max_voxels=%d).'], ...
                stride, n_vox, numel(volume_use_raw), max_voxels);
        end
    end

    [n_nan_scan, n_cap_scan] = plot_utils_scan_isosurface_volume_local( ...
        volume_use_raw, opts_nf.cap_value, ...
        treat_nan_as_blowup_iso);
    info_nf.isosurface_scan_volume_n_nan = double(n_nan_scan);
    info_nf.isosurface_scan_volume_n_cap = double(n_cap_scan);
    if stride == 1
        info_nf.isosurface_full_volume_n_nan = double(n_nan_scan);
        info_nf.isosurface_full_volume_n_cap = double(n_cap_scan);
    else
        info_nf.isosurface_full_volume_n_nan = NaN;
        info_nf.isosurface_full_volume_n_cap = NaN;
    end
    n_scan_total = numel(volume_use_raw);
    if isfinite(n_scan_total) && (n_scan_total > 0) && ...
            ((double(n_nan_scan) + double(n_cap_scan)) >= double(n_scan_total))
        info_nf.isosurface_skip_reason = 'all_nonfinite_or_huge';
        if do_warn
            run_warn_state = plot_utils_emit_softwarn_local( ...
                run_warn_state, phase_tag, do_warn, 'CerUPP:Diagnostics:IsosurfaceAllNonFinite', ...
                'volume_data had no finite samples in the retained plotting volume prior to sanitation; skipping isosurface.');
        end
        return;
    end

    % Sanitize only the retained subvolume after the shape-based large-volume guard
    % has already decided whether downsampling is required.
    diag_label = plot_utils_resolve_diag_label_local( ...
        save_name_new, title_text, 'make_isosurface_plot:volume_data');
    [v_use, naninfo, info_nf_sanitized, run_warn_state] = plot_utils.sanitize_nonfinite_diag( ...
        volume_use_raw, diag_label, opts_nf);
    info_nf = plot_utils_merge_isosurface_sanitize_info_local(info_nf, info_nf_sanitized);

    finite_vals = v_use(isfinite(v_use));
    if isempty(finite_vals)
        info_nf.isosurface_skip_reason = 'all_nonfinite_after_downsample';
        if do_warn
            run_warn_state = plot_utils_emit_softwarn_local( ...
                run_warn_state, phase_tag, do_warn, 'CerUPP:Diagnostics:IsosurfaceAllNonFinite', ...
                'volume_data had no finite samples after sanitation/downsampling; skipping isosurface.');
        end
        return;
    end
    finite_min = min(finite_vals);
    finite_max = max(finite_vals);
    if isfinite(cut_position) && ((cut_position < finite_min) || (cut_position > finite_max))
        info_nf.isosurface_skip_reason = 'cut_position_outside_finite_range';
        if do_warn
            run_warn_state = plot_utils_emit_softwarn_local( ...
                run_warn_state, phase_tag, do_warn, 'CerUPP:Diagnostics:IsosurfaceLevelOutsideFiniteRange', ...
                ['Skipping isosurface because cut_position=%.6g lies outside the finite data range ', ...
                 '[%.6g, %.6g] after sanitation/downsampling.'], ...
                cut_position, finite_min, finite_max);
        end
        return;
    end

    fig_handle = plot_support_utils.open_figure(session.visible_now, true);

    % Build the isosurface here; large-volume remapping stays in one
    % dedicated helper.
    [fv, info_nf] = plot_utils_build_isosurface_faces_local( ...
        x_use, y_use, z_use, v_use, cut_position, ...
        permute_voxels_threshold, do_warn, info_nf);
    p = patch(fv);
    set(p,'FaceColor','b','EdgeColor','none','FaceAlpha',0.2); % translucent blue surface
    if ~isempty(plot_args)
        set(p, plot_args{:});
    end

    % Multiple light sources for depth cues
    lightangle(145,14);    
    lightangle(-100,-20);  
    lightangle(10,20);     
    lighting gouraud;      

    set(gca,'FontSize',20,'Box','On');
    axis tight;
    % Keep MATLAB default aspect scaling for readability when axis ranges
    % are highly disparate (for example, long propagation distance in z).
    % Axis labels still carry the true coordinate units provided by caller.

    view(-154,16); % angled 3D perspective

    xlabel(x_label_disp, 'Interpreter', 'none'); 
    ylabel(y_label_disp, 'Interpreter', 'none');
    zlabel(z_label_disp, 'Interpreter', 'none');
    if isfield(info_nf, 'isosurface_voxel_downsampled') && ...
            logical(info_nf.isosurface_voxel_downsampled) && ...
            isfield(info_nf, 'isosurface_voxel_stride') && ...
            isfinite(info_nf.isosurface_voxel_stride) && ...
            (double(info_nf.isosurface_voxel_stride) > 1)
        title_text_disp = sprintf('%s [isosurface voxel stride=%d]', ...
            title_text_disp, double(info_nf.isosurface_voxel_stride));
    end
    title(title_text_disp, 'Interpreter', 'none');

    % Optional saving
    % save_name_new is a base; extensions are appended conditionally.
    ok = true;
    run_warn_state = plot_support_utils.finalize_plot_success(fig_handle, session, run_warn_state);

catch me
    plot_utils_rethrow_if_contract_error_local(me);
    if isempty(info_nf.isosurface_skip_reason)
        info_nf.isosurface_skip_reason = 'plot_failed';
    end
    if do_warn || (nargout == 0)
        run_warn_state = plot_utils_emit_softwarn_local( ...
            run_warn_state, phase_tag, true, 'CerUPP:Plot:MakeIsosurfaceFailed', ...
            'make_isosurface_plot: plot "%s" failed (%s). Skipping this plot.', ...
            session.save_name_new, me.message);
    end
    plot_support_utils.finalize_plot_close(fig_handle, session);
end

end

function [fv, info_nf] = plot_utils_build_isosurface_faces_local( ...
        x_use, y_use, z_use, v_use, cut_position, ...
        permute_voxels_threshold, do_warn, info_nf)
% Build isosurface faces, keeping large-volume remapping separate from the
% standard vector-axis MATLAB isosurface call.

    nx = numel(x_use);
    ny = numel(y_use);
    nz = numel(z_use);
    use_indexspace_no_permute = isfinite(permute_voxels_threshold) && ...
        (numel(v_use) > permute_voxels_threshold);
    if use_indexspace_no_permute
        % Large-volume path: avoid full permute copy; remap index-space
        % vertices for V_use (Nx-by-Ny-by-Nz):
        %   v(:,1)->dim2 (Ny), v(:,2)->dim1 (Nx), v(:,3)->dim3 (Nz).

        fv = isosurface(v_use, cut_position);
        if isstruct(fv) && isfield(fv, 'vertices') && ~isempty(fv.vertices)
            fv.vertices = plot_utils_remap_isosurface_vertices_local( ...
                fv.vertices, x_use, y_use, z_use, [2 1 3], [nx ny nz]);
        end
        return;
    end

    % Stored V_use is [Nx Ny Nz], but vector-form isosurface(x,y,z,V,iso)
    % expects [Ny Nx Nz].
    v_iso = permute(v_use, [2 1 3]);
    fv = isosurface(x_use, y_use, z_use, v_iso, cut_position);
end

function [n_nan, n_cap] = plot_utils_scan_isosurface_volume_local( ...
        volume_data, cap_hi, treat_nan_as_blowup)
% Lightweight scan over the retained plotting volume used only for skip gating.

    vflat = real(volume_data(:));
    nan_mask = isnan(vflat);
    blow_mask = isinf(vflat) | (isfinite(vflat) & (abs(vflat) > double(cap_hi)));
    n_nan = nnz(nan_mask);
    n_cap = nnz(blow_mask);
    if treat_nan_as_blowup
        blow_mask = blow_mask | nan_mask;
        n_cap = nnz(blow_mask);
        nan_mask(:) = false;
        n_nan = 0;
    end
end

function info_out = plot_utils_merge_isosurface_sanitize_info_local(info_in, info_sanitized)
% Preserve isosurface-specific metadata while copying sanitize_nonfinite_diag info fields.

    info_out = info_in;
    if ~(isstruct(info_sanitized) && isscalar(info_sanitized))
        return;
    end
    sanitize_fields = {'label', 'n_nan', 'n_cap', 'n_replaced', 'cap_hi', ...
        'replace_nonfinite_with_nan', 'count_only', 'had_issue'};
    for kk = 1:numel(sanitize_fields)
        field_name = sanitize_fields{kk};
        if isfield(info_sanitized, field_name)
            info_out.(field_name) = info_sanitized.(field_name);
        end
    end
end

function vertices_xyz = plot_utils_remap_isosurface_vertices_local(vertices_idx, x_axis, y_axis, z_axis, axis_cols, axis_sizes)
% Remap index-space isosurface vertices back onto physical axes with a uniform-axis fast path.

    vertices_xyz = vertices_idx;
    vertices_xyz(:, 1) = plot_utils_axis_index_to_coord_local( ...
        x_axis, vertices_idx(:, axis_cols(1)), axis_sizes(1));
    vertices_xyz(:, 2) = plot_utils_axis_index_to_coord_local( ...
        y_axis, vertices_idx(:, axis_cols(2)), axis_sizes(2));
    vertices_xyz(:, 3) = plot_utils_axis_index_to_coord_local( ...
        z_axis, vertices_idx(:, axis_cols(3)), axis_sizes(3));
end

function coord_vals = plot_utils_axis_index_to_coord_local(axis_vals, idx_vals, axis_len)
% Convert clamped isosurface index coordinates to physical coordinates.

    axis_vals = double(axis_vals(:));
    idx_vals = min(max(double(idx_vals(:)), 1), double(axis_len));
    if isempty(axis_vals)
        coord_vals = idx_vals;
        return;
    end
    if numel(axis_vals) == 1
        coord_vals = repmat(axis_vals(1), size(idx_vals));
        return;
    end
    if plot_utils_axis_is_uniform_local(axis_vals)
        step = (axis_vals(end) - axis_vals(1)) / double(numel(axis_vals) - 1);
        coord_vals = axis_vals(1) + (idx_vals - 1) .* step;
        return;
    end
    coord_vals = interp1(1:numel(axis_vals), axis_vals, idx_vals, 'linear');
end

function run_warn_state = plot_utils_make_scatter3_plot_impl(x_vals, y_vals, z_vals, c_vals, title_text, ...
x_label, y_label, z_label, save_name, ...
plot_settings, varargin)
% Implementation for plot_utils.make_scatter3_plot.
% The public wrapper owns the positional and Name/Value contract. This
% body documents only the local render behavior:
% - x/y/z/c inputs are flattened into one marker stream
% - one shared finite mask drops nonfinite samples before plotting
% - 'uniform' preserves geometric coverage; 'value_ranked' keeps the
%   largest c_vals after the shared selection policy is resolved
% - scatter3 uses filled markers, default size, MATLAB-default view/
%   colormap, and a colorbar

[session, scatter_plot_opts, run_warn_state, phase_tag, do_warn, plot_args] = ...
    plot_utils_begin_renderer_session( ...
    save_name, plot_settings, ...
    [ ...
        struct('field', 'cbar_label', 'names', {{'cbar_label'}}, 'parse_fn', @plot_support_utils.parse_char_scalar, 'default_value', ''), ...
        struct('field', 'max_points', 'names', {{'max_points'}}, 'parse_fn', @plot_support_utils.parse_positive_integer, 'default_value', inf), ...
        struct('field', 'downsample_mode', 'names', {{'downsample_mode'}}, 'parse_fn', @plot_support_utils.parse_downsample_mode, 'default_value', 'uniform') ...
    ], varargin{:});

% Optional colorbar label (strip here so it does not leak downstream).
cbar_label = '';
max_points = inf;
downsample_mode = 'uniform';
cbar_label = scatter_plot_opts.cbar_label;
max_points = scatter_plot_opts.max_points;
downsample_mode = scatter_plot_opts.downsample_mode;

if ~isempty(plot_args) && (mod(numel(plot_args), 2) ~= 0)
    error('CerUPP:PlotArgsOddLength', ...
        'Unparsed plot_args in make_scatter3_plot must be Name/Value pairs (even count). Got %d args.', ...
        numel(plot_args));
end

% Begin plotting
fig_handle = [];
try
    npts = numel(x_vals);
    if (numel(y_vals) ~= npts) || (numel(z_vals) ~= npts) || (numel(c_vals) ~= npts)
        error('make_scatter3_plot:SizeMismatch', ...
            'x/y/z/c inputs must have the same number of elements.');
    end
    early_uniform_downsample = isfinite(max_points) && (npts > max_points) && strcmpi(downsample_mode, 'uniform');
    downsample_note = '';
    if early_uniform_downsample
        if max_points == 1
            keep_idx = 1;
        else
            keep_idx = 1 + floor(((0:(max_points - 1)) .* (npts - 1)) ./ (max_points - 1));
        end
        x_plot = x_vals(keep_idx);
        y_plot = y_vals(keep_idx);
        z_plot = z_vals(keep_idx);
        c_plot = c_vals(keep_idx);
        downsample_note = 'uniform preselection';
    else
        x_plot = x_vals(:);
        y_plot = y_vals(:);
        z_plot = z_vals(:);
        c_plot = c_vals(:);
    end
    finite_mask = isfinite(x_plot) & isfinite(y_plot) & isfinite(z_plot) & isfinite(c_plot);
    dropped_nonfinite = nnz(~finite_mask);
    if do_warn && (dropped_nonfinite > 0)
        run_warn_state = plot_utils_emit_softwarn_local( ...
            run_warn_state, phase_tag, do_warn, 'CerUPP:Plot:NonFiniteDropped', ...
            'make_scatter3_plot dropped %d non-finite points before plotting.', dropped_nonfinite);
    end
    x_plot = x_plot(finite_mask);
    y_plot = y_plot(finite_mask);
    z_plot = z_plot(finite_mask);
    c_plot = c_plot(finite_mask);
    if isempty(x_plot)
        if do_warn
            run_warn_state = plot_utils_emit_softwarn_local( ...
                run_warn_state, phase_tag, do_warn, 'CerUPP:Plot:Skipped', ...
                'make_scatter3_plot skipped for "%s": no finite points after filtering.', session.save_name_new);
        end
        return;
    end
    if ~early_uniform_downsample && isfinite(max_points) && (numel(x_plot) > max_points)
        n_now = numel(x_plot);
        if strcmpi(downsample_mode, 'value_ranked')
            % Value-ranked keep-largest points (hotspot-focused rendering).

            if plot_utils_supports_maxk_local()
                [~, keep_idx] = maxk(c_plot, max_points);
            else
                [~, ord] = sort(c_plot, 'descend');
                keep_idx = ord(1:max_points);
            end
            downsample_note = 'value-ranked keep-largest';
        else
            % Deterministic coverage-preserving sampling in original ordering.

            if max_points == 1
                keep_idx = 1;
            else
                keep_idx = 1 + floor(((0:(max_points - 1)) .* (n_now - 1)) ./ (max_points - 1));
            end
            downsample_note = 'uniform index sampling';
        end
        x_plot = x_plot(keep_idx);
        y_plot = y_plot(keep_idx);
        z_plot = z_plot(keep_idx);
        c_plot = c_plot(keep_idx);
    end
    if early_uniform_downsample && do_warn
        run_warn_state = plot_utils_emit_softwarn_local( ...
            run_warn_state, phase_tag, do_warn, 'CerUPP:Plot:Downsampled', ...
            'make_scatter3_plot downsampled to %d points (%s).', numel(x_plot), downsample_note);
    elseif isfinite(max_points) && (numel(x_plot) <= max_points) && ~isempty(downsample_note)
        % no-op; keep warning ownership with the block that applied the reduction

    elseif isfinite(max_points) && ~isempty(downsample_note) && do_warn
        run_warn_state = plot_utils_emit_softwarn_local( ...
            run_warn_state, phase_tag, do_warn, 'CerUPP:Plot:Downsampled', ...
            'make_scatter3_plot downsampled to %d points (%s).', numel(x_plot), downsample_note);
    end
    % Normalize TeX-like text for plain Interpreter='none' rendering only after data validation succeeds.

    [x_label_disp, y_label_disp, z_label_disp, title_text_disp, cbar_label_disp] = ...
        plot_utils_sanitize_text_bundle_local(x_label, y_label, z_label, title_text, cbar_label);
    fig_handle = plot_support_utils.open_figure(session.visible_now, false);
    % Inputs must be same-size vectors/arrays; each element maps to one marker.

    scatter3(x_plot, y_plot, z_plot, [], c_plot, 'filled', plot_args{:}); % 3D scatter with color by c_vals
    axis tight;
    % Keep MATLAB default aspect scaling for readability when axis ranges
    % are highly disparate. Axis labels still describe true input units.

    xlabel(x_label_disp, 'Interpreter', 'none'); % don't render TeX
    ylabel(y_label_disp, 'Interpreter', 'none');
    zlabel(z_label_disp, 'Interpreter', 'none');
    title(title_text_disp, 'Interpreter', 'none');
    % Display color scale for c_vals.

    cb = colorbar; % maps c_vals to color scale
    if ~isempty(strtrim(cbar_label_disp))
        ylabel(cb, cbar_label_disp, 'Interpreter', 'none');
    end

    % Optional file saving
    % Save outputs if requested; extensions are appended to save_name_new.
    run_warn_state = plot_support_utils.finalize_plot_success(fig_handle, session, run_warn_state);

catch me
    plot_utils_rethrow_if_contract_error_local(me);
    % Quiet-mode contract: best-effort scatter plot failures stay silent when warn=false.

    if do_warn
        run_warn_state = plot_utils_emit_softwarn_local( ...
            run_warn_state, phase_tag, do_warn, 'CerUPP:Plot:Skipped', ...
            'make_scatter3_plot failed for "%s": %s. Skipping this plot.', ...
            session.save_name_new, me.message);
    end
    plot_support_utils.finalize_plot_close(fig_handle, session);
end

end

function cap_out = plot_utils_sanitize_cap_for_array_class_local(cap_in, x_2)
% Ensure cap is finite, positive, and representable in X's numeric class.

    cap_out = double(cap_in);
    if ~isscalar(cap_out) || ~isfinite(cap_out) || ~isreal(cap_out) || (cap_out <= 0)
        cap_out = 1e120;
    end

    if isempty(x_2)
        return;
    end

    x_class = class(x_2);
    switch x_class
        case {'single', 'double'}
            cap_max = realmax(x_class);
        case {'int8','uint8','int16','uint16','int32','uint32','int64','uint64'}
            cap_max = double(intmax(x_class));
        otherwise
            cap_max = inf;
    end

    if isfinite(cap_max)
        cap_out = min(cap_out, cap_max);
    end
end

function diag_scan = plot_utils_scan_diag_values_local(x_in, cap_hi, check_complex)
% Shared diagnostic-value scan for generic plot sanitation helpers.

    if nargin < 3 || isempty(check_complex)
        check_complex = false;
    end
    nan_mask = isnan(x_in);
    blow_mask = isinf(x_in);
    check_huge_mask = isfinite(cap_hi);
    if check_huge_mask && (isa(x_in, 'single') || isa(x_in, 'double'))
        check_huge_mask = (cap_hi < realmax(class(x_in)));
    end
    if check_huge_mask
        blow_mask = blow_mask | (abs(x_in) > cap_hi);
    end
    if check_complex
        real_values = real(x_in);
    else
        real_values = [];
    end
    diag_scan = struct( ...
        'real_values', real_values, ...
        'nan_mask', nan_mask, ...
        'blow_mask', blow_mask, ...
        'n_nan', nnz(nan_mask), ...
        'n_cap', nnz(blow_mask), ...
        'imag_mag', 0, ...
        'real_mag', 0, ...
        'tol_imag', 0, ...
        'complex_leakage', false);
    if ~check_complex
        return;
    end
    finite_mask = isfinite(x_in);
    if any(finite_mask(:))
        diag_scan.imag_mag = max(abs(imag(x_in(finite_mask))));
        diag_scan.real_mag = max(abs(real(x_in(finite_mask))));
    end
    diag_scan.tol_imag = 1e-12 * max(diag_scan.real_mag, 1);
    diag_scan.complex_leakage = (diag_scan.imag_mag > diag_scan.tol_imag);
end

function tf = plot_utils_option_specs_include_field_local(option_specs, field_name)
% True when a renderer option-spec list exposes the requested field.

    tf = false;
    if isempty(option_specs)
        return;
    end
    for kk = 1:numel(option_specs)
        spec = option_specs(kk);
        if iscell(option_specs)
            spec = option_specs{kk};
        end
        if isstruct(spec) && isfield(spec, 'field') && strcmp(char(spec.field), field_name)
            tf = true;
            return;
        end
    end
end

function plot_utils_rethrow_if_contract_error_local(me)
% Let caller/input contract failures propagate instead of masquerading as skipped plots.

    if plot_utils_is_contract_error_local(me)
        rethrow(me);
    end
end

function tf = plot_utils_is_contract_error_local(me)
% True for deliberate helper-input/shape errors that should hard-fail.

    tf = isa(me, 'MException');
    if ~tf
        return;
    end
    err_id = char(string(me.identifier));
    tf = any(strcmp(err_id, plot_utils_contract_error_ids_local()));
    if tf
        return;
    end
    tf = any(startsWith(err_id, { ...
        'plot_utils:', ...
        'make_plot:', ...
        'make_isosurface_plot:', ...
        'make_scatter3_plot:', ...
        'CerUPP:PlotArgs:', ...
        'CerUPP:Plot:'}));
end

function err_ids = plot_utils_contract_error_ids_local()
% Explicit contract-error IDs that should rethrow instead of warn-and-skip.
% Helper-owned validation prefixes are handled in plot_utils_is_contract_error_local.

    err_ids = { ...
        'plot_utils:IgnoredYDataInLineMode', ...
        'plot_utils:IgnoredLegendTextInSurfaceMode', ...
        'make_plot:PositionalOnlyInterface', ...
        'make_plot:LineSizeMismatch', ...
        'make_plot:MultiLineSizeMismatch', ...
        'make_plot:SurfaceSizeMismatch', ...
        'make_isosurface_plot:SizeMismatch', ...
        'make_scatter3_plot:SizeMismatch', ...
        'CerUPP:PlotArgsOddLength', ...
        'CerUPP:PlotArgs:UnknownFigureSessionOption', ...
        'CerUPP:PlotArgs:UnknownFigureFinalizeOption', ...
        'CerUPP:PlotArgs:OutdirMissingValue', ...
        'CerUPP:PlotArgs:OutdirValueType', ...
        'CerUPP:PlotArgs:OutdirEmptyValue', ...
        'CerUPP:PlotArgs:CloseFigureMissingValue', ...
        'CerUPP:PlotArgs:CloseFigureValueType', ...
        'CerUPP:PlotArgs:VisibleMissingValue', ...
        'CerUPP:PlotArgs:VisibleValueType', ...
        'CerUPP:InvalidPlotOptionSpec'};
end
