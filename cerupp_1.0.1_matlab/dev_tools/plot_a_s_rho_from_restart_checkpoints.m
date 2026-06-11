function snapshot_view = plot_a_s_rho_from_restart_checkpoints(run_dir, varargin)
%PLOT_A_S_RHO_FROM_RESTART_CHECKPOINTS Plot checkpoint-held A_S/rho z maps.
% Purpose:
% - Load the compact A_S/rho checkpoint companion series when it exists.
% - Fall back to restart checkpoints when only the restart stream is available.
% - Build sampled t-z plots for Re(A_S), Im(A_S), |A_S|, and rho without
%   asking the ordinary diagnostic store to hold full 4-D A_S/rho histories.
%
% Usage:
%   snapshot_view = plot_a_s_rho_from_restart_checkpoints(run_dir, Name, Value...)
%
% Required input:
%   run_dir : run output root or the checkpoints/ directory for one run.
%
% Name/value options:
%   'out_dir'       : output directory for PNG plots
%                     default = <run root>/checkpoint_snapshot_plots
%                     A checkpoints/ input is first normalized back to its
%                     parent run directory before that default is built.
%   'show_figures'  : true keeps figures visible; false renders hidden
%                     default = false
%   'save_png'      : true writes PNG files under out_dir
%                     default = true
%   'source'        : 'auto', 'snapshot_companion', or 'restart_checkpoint'
%                     default = 'auto'
%   'ix'            : x-index to sample for the t-z traces
%                     default = nearest x to zero
%   'iy'            : y-index to sample for the t-z traces
%                     default = nearest y to zero
%
% Output:
%   snapshot_view : struct with source metadata, sampled z/t axes, and the
%                   sampled A_S/rho checkpoint series.

opts = parse_options(varargin{:});
io_ctx = resolve_io_context(run_dir, opts.out_dir);
[file_records, source_mode] = discover_snapshot_files(io_ctx, opts.source);

if isempty(file_records)
    error('plot_a_s_rho_from_restart_checkpoints:NoCheckpointSeries', ...
        'No usable checkpoint companion or restart-checkpoint files were found under %s.', ...
        io_ctx.check_dir);
end

z_post_m = NaN(numel(file_records), 1);
step_idx = NaN(numel(file_records), 1);
file_names = cell(numel(file_records), 1);
t_s = [];
x_m = [];
y_m = [];
ix = NaN;
iy = NaN;
sample_is_onaxis = false;
sample_label = '';
sample_file_tag = '';
A_S_sampled = [];
rho_sampled = [];

for kk = 1:numel(file_records)
    entry = load_snapshot_entry(file_records(kk), source_mode);
    if isempty(t_s)
        x_m = entry.grid.x(:);
        y_m = entry.grid.y(:);
        t_s = entry.grid.t(:);
        [ix, iy] = resolve_sample_indices(opts, x_m, y_m);
        sample_is_onaxis = is_onaxis_sample_local(ix, iy, x_m, y_m);
        sample_label = ternary(sample_is_onaxis, 'On-axis', 'Sampled');
        sample_file_tag = build_sample_file_tag_local(ix, iy, sample_is_onaxis);
        nt = numel(t_s);
        A_S_sampled = complex(NaN(nt, numel(file_records)));
        rho_sampled = NaN(nt, numel(file_records));
    else
        require_same_grid(entry.grid.x(:), x_m, 'x');
        require_same_grid(entry.grid.y(:), y_m, 'y');
        require_same_grid(entry.grid.t(:), t_s, 't');
    end

    A_S_here = entry.state.A_S;
    rho_here = entry.state.rho;
    if ndims(A_S_here) ~= 3
        error('plot_a_s_rho_from_restart_checkpoints:InvalidASShape', ...
            'A_S in %s must be [Nx x Ny x Nt]; got size %s.', ...
            file_records(kk).path, mat2str(size(A_S_here)));
    end
    if isempty(rho_here)
        rho_here = zeros(size(A_S_here), 'like', real(A_S_here));
    end
    if ndims(rho_here) ~= 3
        error('plot_a_s_rho_from_restart_checkpoints:InvalidRhoShape', ...
            'rho in %s must be [Nx x Ny x Nt]; got size %s.', ...
            file_records(kk).path, mat2str(size(rho_here)));
    end
    if ~isequal(size(A_S_here), size(rho_here))
        error('plot_a_s_rho_from_restart_checkpoints:StateShapeMismatch', ...
            'A_S and rho must share one [Nx x Ny x Nt] shape in %s.', ...
            file_records(kk).path);
    end

    A_S_sampled(:, kk) = reshape(A_S_here(ix, iy, :), [], 1);
    rho_sampled(:, kk) = reshape(real(rho_here(ix, iy, :)), [], 1);
    z_post_m(kk) = entry.progress.z_post_step_m;
    step_idx(kk) = entry.progress.curr_z_step;
    file_names{kk} = file_records(kk).path;
end

[z_post_m, sort_idx] = sort(z_post_m(:), 'ascend');
step_idx = step_idx(sort_idx);
file_names = file_names(sort_idx);
A_S_sampled = A_S_sampled(:, sort_idx);
rho_sampled = rho_sampled(:, sort_idx);

snapshot_view = struct( ...
    'source_mode', char(source_mode), ...
    'checkpoint_dir', io_ctx.check_dir, ...
    'out_dir', io_ctx.out_dir, ...
    'file_names', {file_names}, ...
    'step_idx', step_idx, ...
    'z_post_m', z_post_m, ...
    't_s', t_s, ...
    'x_m', x_m, ...
    'y_m', y_m, ...
    'ix', ix, ...
    'iy', iy, ...
    'sample_is_onaxis', sample_is_onaxis, ...
    'sample_label', sample_label, ...
    'sample_file_tag', sample_file_tag, ...
    'x_sample_m', x_m(ix), ...
    'y_sample_m', y_m(iy), ...
    'A_S_sampled', A_S_sampled, ...
    'rho_sampled', rho_sampled);

if opts.save_png && ~exist(io_ctx.out_dir, 'dir')
    mkdir(io_ctx.out_dir);
end

sample_position_line = build_sample_position_line_local(ix, iy, x_m(ix), y_m(iy));
render_tz_map(z_post_m, t_s, real(A_S_sampled), ...
    {sprintf('%s Re(A_S) from checkpoint snapshots', sample_label), ...
     sample_position_line, ...
     'Stored A_S is the solver envelope on the omega_ref FFT grid'}, ...
    'Re(A_S) [sqrt(W/m^2)]', fullfile(io_ctx.out_dir, sprintf('a_s_real_%s_tz.png', sample_file_tag)), opts);
render_tz_map(z_post_m, t_s, imag(A_S_sampled), ...
    {sprintf('%s Im(A_S) from checkpoint snapshots', sample_label), ...
     sample_position_line, ...
     'Stored A_S is the solver envelope on the omega_ref FFT grid'}, ...
    'Im(A_S) [sqrt(W/m^2)]', fullfile(io_ctx.out_dir, sprintf('a_s_imag_%s_tz.png', sample_file_tag)), opts);
render_tz_map(z_post_m, t_s, abs(A_S_sampled), ...
    {sprintf('%s |A_S| from checkpoint snapshots', sample_label), ...
     sample_position_line, ...
     'Stored A_S is the solver envelope on the omega_ref FFT grid'}, ...
    '|A_S| [sqrt(W/m^2)]', fullfile(io_ctx.out_dir, sprintf('a_s_abs_%s_tz.png', sample_file_tag)), opts);
render_tz_map(z_post_m, t_s, rho_sampled, ...
    {sprintf('%s rho from checkpoint snapshots', sample_label), ...
     sample_position_line, ...
     'rho is plotted in physical density units'}, ...
    'rho [m^-3]', fullfile(io_ctx.out_dir, sprintf('rho_%s_tz.png', sample_file_tag)), opts);
end

function opts = parse_options(varargin)
parser = inputParser;
parser.FunctionName = 'plot_a_s_rho_from_restart_checkpoints';
addParameter(parser, 'out_dir', '', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'show_figures', false, @(x) islogical(x) || isnumeric(x));
addParameter(parser, 'save_png', true, @(x) islogical(x) || isnumeric(x));
addParameter(parser, 'source', 'auto', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'ix', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x) && isfinite(x)));
addParameter(parser, 'iy', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x) && isfinite(x)));
parse(parser, varargin{:});
opts = parser.Results;
opts.source = lower(strtrim(char(string(opts.source))));
opts.out_dir = char(string(opts.out_dir));
opts.show_figures = logical(opts.show_figures);
opts.save_png = logical(opts.save_png);
end

function io_ctx = resolve_io_context(run_dir, out_dir)
run_dir = char(string(run_dir));
if isempty(run_dir)
    error('plot_a_s_rho_from_restart_checkpoints:MissingRunDir', ...
        'run_dir is required.');
end
if exist(fullfile(run_dir, 'checkpoints'), 'dir')
    io_ctx.run_dir = run_dir;
    io_ctx.check_dir = fullfile(run_dir, 'checkpoints');
elseif exist(run_dir, 'dir') && is_checkpoints_dir_local(run_dir)
    io_ctx.check_dir = run_dir;
    io_ctx.run_dir = fileparts(run_dir);
else
    error('plot_a_s_rho_from_restart_checkpoints:MissingCheckpointsDir', ...
        'Could not find checkpoints/ under %s.', run_dir);
end
if isempty(out_dir)
    io_ctx.out_dir = fullfile(io_ctx.run_dir, 'checkpoint_snapshot_plots');
else
    io_ctx.out_dir = out_dir;
end
end

function [file_records, source_mode] = discover_snapshot_files(io_ctx, source_mode_requested)
snapshot_dir = fullfile(io_ctx.check_dir, 'a_s_rho_snapshots');
source_mode = char(source_mode_requested);
file_records = struct('path', {}, 'name', {}, 'step', {});

if strcmp(source_mode, 'auto') || strcmp(source_mode, 'snapshot_companion')
    if exist(snapshot_dir, 'dir')
        snapshot_files = dir(fullfile(snapshot_dir, 'a_s_rho_snapshot_step_*.mat'));
        if ~isempty(snapshot_files)
            file_records = build_file_records(snapshot_dir, snapshot_files, 'a_s_rho_snapshot_step_%d.mat');
            source_mode = 'snapshot_companion';
            return;
        end
    end
    if strcmp(source_mode_requested, 'snapshot_companion')
        return;
    end
end

if ~(strcmp(source_mode, 'auto') || strcmp(source_mode, 'restart_checkpoint'))
    error('plot_a_s_rho_from_restart_checkpoints:InvalidSourceMode', ...
        'source must be auto, snapshot_companion, or restart_checkpoint.');
end

step_files = dir(fullfile(io_ctx.check_dir, 'checkpoint_step_*.mat'));
if ~isempty(step_files)
    file_records = build_file_records(io_ctx.check_dir, step_files, 'checkpoint_step_%d.mat');
    source_mode = 'restart_checkpoint';
    return;
end

latest_file = fullfile(io_ctx.check_dir, 'checkpoint_latest.mat');
if exist(latest_file, 'file')
    file_records = struct( ...
        'path', latest_file, ...
        'name', 'checkpoint_latest.mat', ...
        'step', NaN);
    source_mode = 'restart_checkpoint';
end
end

function file_records = build_file_records(root_dir, files_in, step_pattern)
file_records = repmat(struct('path', '', 'name', '', 'step', NaN), numel(files_in), 1);
for kk = 1:numel(files_in)
    file_records(kk).path = fullfile(root_dir, files_in(kk).name);
    file_records(kk).name = files_in(kk).name;
    step_val = sscanf(files_in(kk).name, step_pattern, 1);
    if isempty(step_val)
        step_val = NaN;
    end
    file_records(kk).step = double(step_val);
end
[~, sort_idx] = sort([file_records.step]);
file_records = file_records(sort_idx);
end

function entry = load_snapshot_entry(file_record, source_mode)
switch source_mode
    case 'snapshot_companion'
        raw = load(file_record.path, 'a_s_rho_snapshot');
        if ~isfield(raw, 'a_s_rho_snapshot') || isempty(raw.a_s_rho_snapshot)
            error('plot_a_s_rho_from_restart_checkpoints:MissingSnapshotPayload', ...
                'Missing a_s_rho_snapshot in %s.', file_record.path);
        end
        entry = raw.a_s_rho_snapshot;
    case 'restart_checkpoint'
        raw = load(file_record.path, 'restart_state');
        if ~isfield(raw, 'restart_state') || isempty(raw.restart_state)
            error('plot_a_s_rho_from_restart_checkpoints:MissingRestartState', ...
                'Missing restart_state in %s.', file_record.path);
        end
        rs = resolve_restart_common_groups_for_snapshot_local( ...
            raw.restart_state, file_record.path);
        if ~isfield(rs, 'state') || ~isfield(rs, 'grid') || ~isfield(rs, 'progress')
            error('plot_a_s_rho_from_restart_checkpoints:InvalidRestartPayload', ...
                'restart_state in %s is missing progress/state/grid.', file_record.path);
        end
        z_pre_m = NaN;
        if isfield(rs.progress, 'z_pre_step_m')
            z_pre_m = double(rs.progress.z_pre_step_m);
        elseif isfield(rs.progress, 'z_curr')
            z_pre_m = double(rs.progress.z_curr);
        end
        z_post_m = NaN;
        if isfield(rs.progress, 'z_post_step_m')
            z_post_m = double(rs.progress.z_post_step_m);
        end
        dz_m = NaN;
        if isfield(rs.progress, 'dz')
            dz_m = double(rs.progress.dz);
        end
        if ~isfinite(z_post_m) && isfinite(z_pre_m) && isfinite(dz_m)
            z_post_m = z_pre_m + dz_m;
        end
        entry = struct( ...
            'progress', struct( ...
                'curr_z_step', double(get_optional_field(rs.progress, 'curr_z_step', file_record.step)), ...
                'z_pre_step_m', z_pre_m, ...
                'z_post_step_m', z_post_m, ...
                'dz_m', dz_m), ...
            'state', struct( ...
                'A_S', rs.state.A_S, ...
                'rho', rs.state.rho), ...
            'grid', struct( ...
                'x', rs.grid.x, ...
                'y', rs.grid.y, ...
                't', rs.grid.t));
    otherwise
        error('plot_a_s_rho_from_restart_checkpoints:InvalidSourceMode', ...
            'Unsupported source mode %s.', source_mode);
end
end

function rs = resolve_restart_common_groups_for_snapshot_local(rs, checkpoint_path)
if ~(isstruct(rs) && isscalar(rs))
    error('plot_a_s_rho_from_restart_checkpoints:InvalidRestartPayload', ...
        'restart_state in %s must be a scalar struct.', checkpoint_path);
end

common_group_names = {'grid', 'medium', 'ops'};
present_groups = common_group_names(isfield(rs, common_group_names));
if isempty(present_groups)
    return;
end

companion_file = '';
referenced_groups = {};
for ii = 1:numel(present_groups)
    group_name = present_groups{ii};
    group_value = rs.(group_name);
    if is_restart_common_group_companion_ref_local(group_value)
        referenced_groups{end+1} = group_name; %#ok<AGROW>
        group_companion_file = char(string(group_value.sidecar_file));
        if isempty(companion_file)
            companion_file = group_companion_file;
        elseif ~strcmp(companion_file, group_companion_file)
            error('plot_a_s_rho_from_restart_checkpoints:MixedCommonGroupFiles', ...
                ['restart_state in %s references multiple common-group ', ...
                 'companion files (%s vs %s).'], ...
                checkpoint_path, companion_file, group_companion_file);
        end
    end
end

if isempty(referenced_groups)
    return;
end

check_dir = fileparts(checkpoint_path);
companion_path = fullfile(check_dir, companion_file);
if exist(companion_path, 'file') ~= 2
    error('plot_a_s_rho_from_restart_checkpoints:MissingCommonGroupFile', ...
        'restart_state in %s references missing common-group companion file %s.', ...
        checkpoint_path, companion_path);
end

raw_common = load(companion_path, 'restart_common_groups');
if ~isfield(raw_common, 'restart_common_groups') || ...
        ~(isstruct(raw_common.restart_common_groups) && isscalar(raw_common.restart_common_groups))
    error('plot_a_s_rho_from_restart_checkpoints:InvalidCommonGroupFile', ...
        ['Common-group companion file %s for checkpoint %s does not contain ', ...
         'a scalar restart_common_groups struct.'], ...
        companion_path, checkpoint_path);
end

common_groups = raw_common.restart_common_groups;
for ii = 1:numel(referenced_groups)
    group_name = referenced_groups{ii};
    if ~isfield(common_groups, group_name) || ...
            ~(isstruct(common_groups.(group_name)) && isscalar(common_groups.(group_name)))
        error('plot_a_s_rho_from_restart_checkpoints:MissingCommonGroup', ...
            ['Common-group companion file %s for checkpoint %s is missing ', ...
             'scalar group "%s".'], ...
            companion_path, checkpoint_path, group_name);
    end
    rs.(group_name) = common_groups.(group_name);
end
end

function tf = is_restart_common_group_companion_ref_local(value_in)
tf = isstruct(value_in) && isscalar(value_in) && ...
    isfield(value_in, 'storage_owner') && ...
    isfield(value_in, 'sidecar_file') && ...
    strcmp(char(string(value_in.storage_owner)), ...
        'checkpoint_common_groups_sidecar_ref');
end

function value = get_optional_field(source_struct, field_name, fallback_value)
value = fallback_value;
if isfield(source_struct, field_name) && ~isempty(source_struct.(field_name))
    value = source_struct.(field_name);
end
end

function [ix, iy] = resolve_sample_indices(opts, x_m, y_m)
if isempty(opts.ix)
    [~, ix] = min(abs(x_m));
else
    ix = max(1, min(numel(x_m), round(double(opts.ix))));
end
if isempty(opts.iy)
    [~, iy] = min(abs(y_m));
else
    iy = max(1, min(numel(y_m), round(double(opts.iy))));
end
end

function tf = is_onaxis_sample_local(ix, iy, x_m, y_m)
[~, ix_zero] = min(abs(x_m));
[~, iy_zero] = min(abs(y_m));
tf = (ix == ix_zero) && (iy == iy_zero);
end

function sample_file_tag = build_sample_file_tag_local(ix, iy, sample_is_onaxis)
if sample_is_onaxis
    sample_file_tag = 'onaxis';
else
    sample_file_tag = sprintf('sample_ix%d_iy%d', ix, iy);
end
end

function line_txt = build_sample_position_line_local(ix, iy, x_sample_m, y_sample_m)
line_txt = sprintf('Sample point: ix=%d, iy=%d, x=%.6g m, y=%.6g m', ...
    ix, iy, x_sample_m, y_sample_m);
end

function require_same_grid(grid_in, grid_ref, grid_name)
if numel(grid_in) ~= numel(grid_ref) || any(grid_in(:) ~= grid_ref(:))
    error('plot_a_s_rho_from_restart_checkpoints:GridMismatch', ...
        'Checkpoint series changed the %s grid, so one common t-z plot is not well-defined.', ...
        grid_name);
end
end

function render_tz_map(z_post_m, t_s, data_tz, title_lines, cbar_label, png_path, opts)
fig = figure('Visible', ternary(opts.show_figures, 'on', 'off'));
imagesc(z_post_m(:).' / 1e-3, t_s(:) / 1e-15, data_tz);
axis xy;
xlabel('z_{post} [mm]');
ylabel('t [fs] (pulse-frame)');
title(title_lines);
cb = colorbar;
ylabel(cb, cbar_label);
if opts.save_png
    exportgraphics(fig, png_path, 'Resolution', 160);
end
if ~opts.show_figures
    close(fig);
end
end

function out = ternary(cond, true_value, false_value)
if cond
    out = true_value;
else
    out = false_value;
end
end

function tf = is_checkpoints_dir_local(dir_path)
[~, base_name, ext] = fileparts(dir_path);
tf = strcmpi([base_name ext], 'checkpoints');
end
