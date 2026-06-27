function diag = assemble_diagnostics_from_restart(run_dir, varargin)
%ASSEMBLE_DIAGNOSTICS_FROM_RESTART Rebuild stored diagnostics from restart checkpoints.
% Purpose:
% - Reassemble the current stored-diagnostic families from restart/checkpoint files.
% - This is an offline dev-tool rebuild path only; it does not resume propagation.
% Usage
%   diag = assemble_diagnostics_from_restart(run_dir, Name=Value...)
%
% Required input
%   run_dir : saved run directory containing checkpoints/ for one
%             propagation run.
%
% Key options
%   'latest_only'           : logical-like scalar, default false; rebuild only
%                             one usable restart payload. By default this
%                             prefers the highest checkpoint_step_* index
%                             (falling back to datenum if needed); set
%                             prefer_latest_pointer=true to try
%                             checkpoint_latest.mat first.
%   'rebuild_families'      : requested rebuild family or family list.
%                             Explicit requests are strict-selective: only
%                             the requested families plus the common plane
%                             index fields are rebuilt. The default keeps
%                             the full standard family set
%                             {'core','bands_rgb','full_spectrum','plasma_nla'}.
%   'make_plots' / 'outdir' : optional quick-look plots and their output folder.
%   'verify_saved_payload'  : run the shared minimal MAT-payload verification
%                             after saving the reassembled diagnostics artifact.
%
% Output
%   diag : reconstructed diagnostics struct containing source/checkpoint
%          metadata, reassembly status metadata, and any rebuilt
%          store_* diagnostics.
%
% Notes
% - This helper rebuilds diagnostics from saved checkpoint payloads; it does
%   not resume propagation or participate in the live runtime path.
% - Reassembly uses the strict-schema restart contract.
% - The restart/reassembly contract, artifact naming, and strict-schema
%   expectations are documented in the CerUPP manual under the restart
%   workflow and output-artifact sections.
% Workflow
% - resolve the rebuild policy and run-directory context
% - discover usable checkpoint payloads
% - rebuild the requested diagnostic families
% - save, and optionally verify and plot the reconstructed artifact

this_dir = fileparts(mfilename('fullpath'));
if isempty(this_dir)
    this_dir = pwd;
end
original_path = path;
restore_path_cleanup = onCleanup(@() path(original_path)); %#ok<NASGU>
dev_tools_dir = fileparts(this_dir);
root_dir = fileparts(dev_tools_dir);
utils_dir = fullfile(root_dir, 'utils');
if exist(root_dir, 'dir')
    addpath(root_dir);
end
if exist(utils_dir, 'dir')
    addpath(utils_dir);
end

p = inputParser;
p.addRequired('run_dir', @(s) ischar(s) || (isstring(s) && isscalar(s)));
p.addParameter('make_plots', false, @(x) isscalar(x) && (islogical(x) || isnumeric(x)));
p.addParameter('outdir', '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
p.addParameter('latest_only', false, @(x) isscalar(x) && (islogical(x) || isnumeric(x)));
p.addParameter('prefer_latest_pointer', false, @(x) isscalar(x) && (islogical(x) || isnumeric(x)));
p.addParameter('verify_saved_payload', true, @(x) isscalar(x) && (islogical(x) || isnumeric(x)));
p.addParameter('rebuild_families', {'core', 'bands_rgb', 'full_spectrum', 'plasma_nla'}, ...
    @(x) ischar(x) || isstring(x) || iscell(x));
p.parse(run_dir, varargin{:});

run_dir = char(p.Results.run_dir);
make_plots = struct_utils.normalize_bool_scalar( ...
    p.Results.make_plots, 'make_plots', 'CerUPP:InvalidMakePlotsFlag');
outdir = char(p.Results.outdir);
latest_only = struct_utils.normalize_bool_scalar( ...
    p.Results.latest_only, 'latest_only', 'CerUPP:InvalidLatestOnlyFlag');
prefer_latest_pointer = struct_utils.normalize_bool_scalar( ...
    p.Results.prefer_latest_pointer, 'prefer_latest_pointer', ...
    'CerUPP:InvalidPreferLatestPointerFlag');
verify_saved_payload = struct_utils.normalize_bool_scalar( ...
    p.Results.verify_saved_payload, 'verify_saved_payload', ...
    'CerUPP:InvalidVerifySavedPayloadFlag');
rebuild_policy = normalize_reassembly_rebuild_policy_local( ...
    p.Results.rebuild_families, any(strcmp(p.UsingDefaults, 'rebuild_families')));
setup_ctx = build_reassembly_setup_ctx_local( ...
    run_dir, make_plots, outdir, ...
    latest_only, prefer_latest_pointer, ...
    verify_saved_payload, rebuild_policy);
selection_policy = setup_ctx.selection_policy;
rebuild_policy = setup_ctx.rebuild_policy;
io_ctx = setup_ctx.io_ctx;
reassembly_warn_owner = setup_ctx.warning_owner;
reassembly_warn_phase = setup_ctx.warning_phase;
reassembly_warn_state = setup_ctx.warning_state;
restart_compat_version_expected = checkpoint_utils.restart_compat_version();
diag_output_name = setup_ctx.diag_output_name;
diag_scope = setup_ctx.diag_scope;
diag_output_file = io_ctx.diag_output_file;
outdir = io_ctx.outdir;
restart_sidecar_cache = init_restart_sidecar_cache_local();
payload_cache_budget_bytes = 256 * 1024^2;
payload_cache_bytes = 0;

[candidate_ctx, reassembly_warn_state] = collect_checkpoint_candidates_local( ...
    io_ctx.check_dir, run_dir, selection_policy, ...
    diag_scope, diag_output_name, diag_output_file, ...
    reassembly_warn_state, reassembly_warn_phase);
files = candidate_ctx.files;
step_idx = candidate_ctx.step_idx;
diag_scope = candidate_ctx.diag_scope;
diag_output_name = candidate_ctx.diag_output_name;
diag_output_file = candidate_ctx.diag_output_file;
io_ctx.diag_output_file = diag_output_file;

file_records = init_reassembly_file_records_local(files, step_idx);

diag = struct();
diag.source_run_dir = io_ctx.run_dir;
diag.source_checkpoint_dir = io_ctx.check_dir;
[restart_schema_tag, restart_schema_ver] = checkpoint_utils.restart_schema_info();
diag.restart_schema_expected = restart_schema_tag;
diag.restart_schema_version_expected = restart_schema_ver;
diag.restart_compat_version_expected = double(restart_compat_version_expected);
diag.reassembly_units_mode = 'actual_physical_units_n_over_nref_weighted_intensity';
diag.reassembly_metric_mode = 'mixed_or_unknown';
diag.reassembly_meta = struct( ...
    'selection_policy', selection_policy, ...
    'rebuild_policy', rebuild_policy, ...
    'units_mode', diag.reassembly_units_mode, ...
    'metric_mode', diag.reassembly_metric_mode, ...
    'weighted_metric_complete', false, ...
    'metric_mode_status', 'unknown', ...
    'metric_mode_notes', {{}}, ...
    'scope', diag_scope, ...
    'warning_owner', reassembly_warn_owner, ...
    'warning_phase', reassembly_warn_phase, ...
    'output_file', io_ctx.diag_output_file, ...
    'output_verify_saved_payload_flag', logical(io_ctx.verify_saved_payload_flag), ...
    'latest_only_selected_file', '', ...
    'latest_only_selected_store_step_idx', NaN, ...
    'latest_only_selection_policy', '', ...
    'selected_plane_ordering_policy', '', ...
    'diag_field_contract', checkpoint_utils.reassembly_diag_field_contract());
diag.expected_grid_shape = [];
diag.reassembly_grid_ref_ctx = struct();
reassembly_issue_ledger = init_reassembly_issue_ledger_local(numel(file_records));
stores_allocated = false;
best_latest_idx = [];
best_latest_policy = '';
selected_step_record_idx = zeros(0, 1);

for k = 1:numel(file_records)
    checkpoint_name = file_records(k).name;
    try
        s = load(fullfile(io_ctx.check_dir, checkpoint_name), 'restart_state');
    catch me_load
        reassembly_issue_ledger = record_reassembly_issue_local( ...
            reassembly_issue_ledger, 'restart_load', checkpoint_name, '');
        file_records = set_reassembly_record_status_local( ...
            file_records, k, 'restart_schema', 'load_failed', '');
        file_records = set_reassembly_record_status_local( ...
            file_records, k, 'reassembly_detail', 'load_failed', '');
        file_records(k).rebuild_meta = struct( ...
            'load_failure_identifier', char(me_load.identifier), ...
            'load_failure_message', char(me_load.message));
        continue;
    end
    if ~isfield(s, 'restart_state') || isempty(s.restart_state)
        reassembly_issue_ledger = record_reassembly_issue_local( ...
            reassembly_issue_ledger, 'missing_restart_state', checkpoint_name, '');
        file_records = set_reassembly_record_status_local( ...
            file_records, k, 'reassembly_detail', 'missing_restart_state', '');
        continue;
    end
    [rs, restart_sidecar_cache] = require_restart_payload_groups_local( ...
        s.restart_state, io_ctx.check_dir, checkpoint_name, restart_sidecar_cache);
    checkpoint_restart_compat_version = extract_restart_compat_version_local(rs, checkpoint_name);
    if checkpoint_restart_compat_version ~= double(restart_compat_version_expected)
        error('CerUPP:RestartCompatVersionMismatch', ...
            ['Restart checkpoint %s was written with restart_compat_version=%d, but ', ...
             'assemble_diagnostics_from_restart expects restart_compat_version=%d.'], ...
            checkpoint_name, checkpoint_restart_compat_version, double(restart_compat_version_expected));
    end
    if isfield(rs.progress, 'curr_z_step') && ...
            is_valid_reassembly_store_step_idx_local(rs.progress.curr_z_step)
        file_records(k).store_step_idx = double(rs.progress.curr_z_step);
    end

    schema_name = 'missing_restart_schema_metadata';
    schema_ver = NaN;
    if isfield(rs, 'restart_schema')
        try
            schema_name = char(string(rs.restart_schema));
        catch
            schema_name = 'unreadable_schema_tag';
        end
    end
    if isfield(rs, 'restart_schema_version') && isnumeric(rs.restart_schema_version) && ...
            isscalar(rs.restart_schema_version) && isfinite(rs.restart_schema_version)
        schema_ver = double(rs.restart_schema_version);
    end
    suffix_unversioned = '_unversioned';
    schema_name_is_missing_versioned_schema = strcmp(schema_name, 'missing_restart_schema_metadata') || ...
        (ischar(schema_name) && (numel(schema_name) >= numel(suffix_unversioned)) && ...
         strcmp(schema_name(end-numel(suffix_unversioned)+1:end), suffix_unversioned));
    if schema_name_is_missing_versioned_schema
        schema_name = 'missing_restart_schema_metadata';
    end
    file_records(k).restart_schema_detected = schema_name;
    file_records(k).restart_schema_version_detected = schema_ver;

    if schema_name_is_missing_versioned_schema
        error('CerUPP:RestartSchemaMissingStrict', ...
            ['Restart payload schema metadata is missing in %s under the strict-schema restart contract. ' ...
             'Restart reassembly requires versioned strict-schema metadata.'], checkpoint_name);
    elseif ~strcmp(schema_name, diag.restart_schema_expected) || ...
            ~(isfinite(schema_ver) && (schema_ver == diag.restart_schema_version_expected))
        error('CerUPP:RestartSchemaMismatchStrict', ...
            ['Restart payload schema mismatch in %s under the strict-schema restart contract. ' ...
             'Expected %s v%d; detected %s v%s.'], ...
            checkpoint_name, diag.restart_schema_expected, ...
            diag.restart_schema_version_expected, schema_name, mat2str(schema_ver));
    else
        file_records = set_reassembly_record_status_local( ...
            file_records, k, 'restart_schema', 'ok', '');
    end

    if ~isfield(rs.state, 'A_S') || isempty(rs.state.A_S)
        [file_records, reassembly_warn_state] = reject_checkpoint_candidate_local( ...
            file_records, k, checkpoint_name, ...
            'reassembly_detail', 'missing_A_s', '', ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'CerUPP:MissingAsInRestartState', ...
            'Skipping %s (missing A_S).');
        continue;
    end
    if ~isfield(rs.grid, 't') || isempty(rs.grid.t) || ...
            ~isfield(rs.grid, 'x') || isempty(rs.grid.x) || ...
            ~isfield(rs.grid, 'y') || isempty(rs.grid.y)
        [file_records, reassembly_warn_state] = reject_checkpoint_candidate_local( ...
            file_records, k, checkpoint_name, ...
            'reassembly_detail', 'missing_grid', '', ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'CerUPP:MissingGridInRestartState', ...
            'Skipping %s (missing x/y/t grids).');
        continue;
    end

    A_S = rs.state.A_S;
    x = rs.grid.x(:);
    y = rs.grid.y(:);
    t = rs.grid.t(:).';
    [nx, ny, nt] = size(A_S);
    if numel(x) ~= nx || numel(y) ~= ny || numel(t) ~= nt
        [file_records, reassembly_warn_state] = reject_checkpoint_candidate_local( ...
            file_records, k, checkpoint_name, ...
            'reassembly_detail', 'grid_size_mismatch', '', ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'CerUPP:GridSizeMismatchInRestartState', ...
            'Skipping %s (A_S and x/y/t sizes mismatch).');
        continue;
    end

    if ~selection_policy.latest_only && ~isempty(diag.expected_grid_shape) && ...
            ~isequal(diag.expected_grid_shape, [nx, ny, nt])
        [file_records, reassembly_warn_state] = reject_checkpoint_candidate_local( ...
            file_records, k, checkpoint_name, ...
            'reassembly_detail', 'grid_shape_mismatch_skip', '', ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'CerUPP:RestartGridShapeMismatchSkip', ...
            ['Skipping %s because its grid shape [%d %d %d] does not match the ', ...
             'established reconstruction shape [%d %d %d].'], ...
            nx, ny, nt, diag.expected_grid_shape(1), ...
            diag.expected_grid_shape(2), diag.expected_grid_shape(3));
        continue;
    end
    if ~selection_policy.latest_only && has_reassembly_grid_ref_ctx_local(diag)
        [grid_vectors_match, grid_mismatch_detail, grid_mismatch_msg] = ...
            compare_reassembly_grid_vectors_local(diag.reassembly_grid_ref_ctx, x, y, t);
        if ~grid_vectors_match
            [file_records, reassembly_warn_state] = reject_checkpoint_candidate_local( ...
                file_records, k, checkpoint_name, ...
                'reassembly_detail', 'grid_vector_mismatch_skip', grid_mismatch_detail, ...
                reassembly_warn_state, reassembly_warn_phase, ...
                'CerUPP:RestartGridVectorMismatchSkip', ...
                ['Skipping %s because its physical x/y/t grid vectors do not match the ', ...
                 'established reassembly grid from %s (%s).'], ...
                diag.reassembly_grid_ref_ctx.checkpoint_name, grid_mismatch_msg);
            continue;
        end
    end

    [n_ratio_diag_xy, diag_weight_ok, diag_weight_reason, diag_weight_note] = ...
        build_restart_diag_weight_map_local(rs, nx, ny, nt, real(A_S(1)));

    candidate_input = build_validated_reassembly_candidate_input_local( ...
        nx, ny, nt, diag_weight_ok, diag_weight_reason, diag_weight_note);

    if isfield(rs, 'progress') && isstruct(rs.progress) && ...
            isfield(rs.progress, 'z_post_step_m') && isnumeric(rs.progress.z_post_step_m) && ...
            isscalar(rs.progress.z_post_step_m) && isfinite(rs.progress.z_post_step_m)
        file_records(k).selected_store_z = double(rs.progress.z_post_step_m);
    elseif isfield(rs, 'progress') && isstruct(rs.progress) && ...
            isfield(rs.progress, 'z_curr') && isnumeric(rs.progress.z_curr) && ...
            isscalar(rs.progress.z_curr) && isfinite(rs.progress.z_curr)
        file_records(k).selected_store_z = double(rs.progress.z_curr);
    end
    file_records(k).validated_candidate_input = candidate_input;
    file_records(k).validated = true;
    [file_records(k), payload_cache_bytes] = maybe_cache_validated_reassembly_payload_local( ...
        file_records(k), rs, x, y, t, n_ratio_diag_xy, A_S, ...
        payload_cache_bytes, payload_cache_budget_bytes);
    if selection_policy.latest_only
        diag.expected_grid_shape = [nx, ny, nt];
        diag = set_reassembly_grid_ref_ctx_local(diag, x, y, t, checkpoint_name);
        best_latest_idx = k;
        if selection_policy.prefer_latest_pointer && strcmp(checkpoint_name, 'checkpoint_latest.mat')
            best_latest_policy = 'prefer_latest_pointer';
        else
            best_latest_policy = 'max_store_step_idx_then_datenum';
        end
        break;
    end

    if isempty(diag.expected_grid_shape)
        diag.expected_grid_shape = [nx, ny, nt];
    end
    selected_step_record_idx(end+1, 1) = k; %#ok<AGROW>
    if ~has_reassembly_grid_ref_ctx_local(diag)
        diag = set_reassembly_grid_ref_ctx_local(diag, x, y, t, checkpoint_name);
    end
    file_records(k).selected = true;
end

if selection_policy.latest_only
    if isempty(best_latest_idx)
        diag.reassembly_meta.latest_only_selected_file = '';
        diag.reassembly_meta.latest_only_selected_store_step_idx = NaN;
        diag.reassembly_meta.latest_only_selection_policy = '';
    else
        selected_step_record_idx = best_latest_idx;
        selected_record = file_records(best_latest_idx);
        candidate_input = require_validated_reassembly_candidate_input_local(selected_record);
        diag.expected_grid_shape = candidate_input.grid_shape;
        diag.reassembly_meta.selected_plane_ordering_policy = best_latest_policy;
        diag = init_diag_store_local( ...
            diag, 1, diag.expected_grid_shape(1), diag.expected_grid_shape(2), diag.expected_grid_shape(3));
        stores_allocated = true;
    end
else
    if ~isempty(selected_step_record_idx)
        [selected_step_record_idx, selected_ordering_meta] = sort_selected_record_idx_local( ...
            selected_step_record_idx, file_records);
        diag.reassembly_meta.selected_plane_ordering_policy = selected_ordering_meta.policy;
        if isfield(selected_ordering_meta, 'warning_key') && ~isempty(selected_ordering_meta.warning_key)
            reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                reassembly_warn_state, reassembly_warn_phase, ...
                selected_ordering_meta.warning_key, selected_ordering_meta.warning_id, ...
                '%s', selected_ordering_meta.warning_message);
        end
        diag = init_diag_store_local( ...
            diag, numel(selected_step_record_idx), diag.expected_grid_shape(1), ...
            diag.expected_grid_shape(2), diag.expected_grid_shape(3));
        stores_allocated = true;
    end
    diag.reassembly_meta.latest_only_selected_file = '';
    diag.reassembly_meta.latest_only_selected_store_step_idx = NaN;
    diag.reassembly_meta.latest_only_selection_policy = '';
end

if stores_allocated
    [diag, file_records, reassembly_warn_state, reassembly_issue_ledger] = ...
        rebuild_selected_reassembly_records_local( ...
            diag, file_records, selected_step_record_idx, ...
            io_ctx.check_dir, rebuild_policy, ...
            reassembly_warn_state, reassembly_warn_phase, ...
            reassembly_issue_ledger);
end

if selection_policy.latest_only && ~isempty(best_latest_idx)
    selected_record = file_records(best_latest_idx);
    diag.reassembly_meta.latest_only_selected_file = selected_record.name;
    diag.reassembly_meta.latest_only_selected_store_step_idx = selected_record.store_step_idx;
    diag.reassembly_meta.latest_only_selection_policy = best_latest_policy;
end

diag = sync_reassembly_selection_summary_local(diag, file_records, selection_policy.latest_only);
diag = finalize_reassembly_issue_ledger_local(diag, reassembly_issue_ledger);
diag = finalize_reassembly_metric_status_local(diag, file_records, selected_step_record_idx);
reassembly_warn_state = emit_batched_reassembly_issue_warnings_local( ...
    reassembly_warn_state, reassembly_warn_phase, reassembly_issue_ledger);

[diag, file_records] = publish_reassembly_file_record_views_local( ...
    diag, file_records, ...
    selected_step_record_idx, selection_policy, ...
    stores_allocated);

if ~stores_allocated
    diag.store_step_idx = [];
    finalize_and_save_reassembled_diag_local( ...
        diag, reassembly_warn_state, reassembly_warn_owner, io_ctx);
    return;
end

reassembly_warn_state = emit_optional_reassembled_plots_local( ...
    diag, make_plots, io_ctx, reassembly_warn_state, reassembly_warn_phase);
finalize_and_save_reassembled_diag_local( ...
    diag, reassembly_warn_state, reassembly_warn_owner, io_ctx);
end

function [candidate_ctx, reassembly_warn_state] = collect_checkpoint_candidates_local( ...
        check_dir, run_dir, selection_policy, diag_scope_in, diag_output_name_in, ...
        diag_output_file_in, reassembly_warn_state, reassembly_warn_phase)
% Collect the ordered checkpoint candidates for latest-only and full-set reassembly.
    latest = dir(fullfile(check_dir, 'checkpoint_latest.mat'));
    step_files = dir(fullfile(check_dir, 'checkpoint_step_*.mat'));
    diag_scope_in = char(string(diag_scope_in));
    diag_output_name_in = char(string(diag_output_name_in));
    diag_output_file_in = char(string(diag_output_file_in));
    candidate_ctx = struct( ...
        'files', [], ...
        'step_idx', [], ...
        'diag_scope', diag_scope_in, ...
        'diag_output_name', diag_output_name_in, ...
        'diag_output_file', diag_output_file_in);

    if selection_policy.latest_only
        latest_files = [];
        latest_step_idx = [];
        sorted_step_files = [];
        sorted_step_idx = [];
        if ~isempty(latest)
            latest_files = latest(1);
            latest_step_idx = NaN;
        end
        if ~isempty(step_files)
            step_vals = nan(numel(step_files), 1);
            for k = 1:numel(step_files)
                step = sscanf(step_files(k).name, 'checkpoint_step_%d.mat', 1);
                if ~isempty(step) && isfinite(step(1))
                    step_vals(k) = double(step(1));
                end
            end
            if any(isfinite(step_vals))
                [~, order] = sort(step_vals, 'descend', 'MissingPlacement', 'last');
            elseif isfield(step_files, 'datenum')
                [~, order] = sort([step_files.datenum], 'descend');
            else
                order = 1:numel(step_files);
            end
            sorted_step_files = step_files(order);
            sorted_step_idx = step_vals(order);
        end
        if selection_policy.prefer_latest_pointer
            candidate_ctx.files = [latest_files(:); sorted_step_files(:)];
            candidate_ctx.step_idx = [latest_step_idx(:); sorted_step_idx(:)];
        else
            candidate_ctx.files = [sorted_step_files(:); latest_files(:)];
            candidate_ctx.step_idx = [sorted_step_idx(:); latest_step_idx(:)];
        end
        if isempty(candidate_ctx.files)
            error('CerUPP:NoCheckpointFiles', ...
                'No checkpoint_step_*.mat or checkpoint_latest.mat found in %s', check_dir);
        end
        return;
    end

    candidate_ctx.files = step_files;
    if isempty(candidate_ctx.files)
        if isempty(latest)
            error('CerUPP:NoCheckpointFiles', ...
                'No checkpoint_step_*.mat or checkpoint_latest.mat found in %s', check_dir);
        end
        reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'only_latest_checkpoint', 'CerUPP:OnlyLatestCheckpoint', ...
            ['No checkpoint_step_*.mat files found in %s, but checkpoint_latest.mat exists. ' ...
             'Reassembling diagnostics for the latest checkpoint only.'], check_dir);
        candidate_ctx.diag_scope = 'fallback_latest_only';
        candidate_ctx.diag_output_name = 'diagnostics_from_restart_fallback_latest.mat';
        candidate_ctx.diag_output_file = fullfile(run_dir, candidate_ctx.diag_output_name);
        candidate_ctx.files = latest(1);
        candidate_ctx.step_idx = NaN;
        return;
    end

    candidate_ctx.step_idx = zeros(numel(candidate_ctx.files), 1);
    for k = 1:numel(candidate_ctx.files)
        step = sscanf(candidate_ctx.files(k).name, 'checkpoint_step_%d.mat', 1);
        if isempty(step)
            candidate_ctx.step_idx(k) = inf;
        else
            candidate_ctx.step_idx(k) = double(step(1));
        end
    end
    [~, order] = sort(candidate_ctx.step_idx, 'ascend');
    candidate_ctx.files = candidate_ctx.files(order);
    candidate_ctx.step_idx = candidate_ctx.step_idx(order);
end

function reassembly_warn_state = emit_reassembled_oa_peak_plot_local( ...
        z_vals, peak_oa, reassembly_metric_mode, outdir, reassembly_warn_state)
% Emit the optional restart-reassembly on-axis peak-over-pulse-frame-t intensity estimate.
    if nargin < 5 || ~isstruct(reassembly_warn_state)
        reassembly_warn_state = struct();
    end
    reassembly_warn_state = struct_utils.ensure_warned_keys_map(reassembly_warn_state);
    if isempty(outdir)
        return;
    end
    title_text = 'Reassembled on-axis (axis-nearest) peak over pulse-frame t intensity estimate vs z';
    metric_mode_text = reassembly_metric_mode_text_local(reassembly_metric_mode);
    if ~isempty(metric_mode_text)
        title_text = sprintf('%s (%s)', title_text, metric_mode_text);
    end
    plot_settings = struct( ...
        'outdir', outdir, ...
        'warn', true, ...
        'visible', false, ...
        'save_outputs_as_fig', false, ...
        'save_outputs_as_png', true);
    [~, ~, ~, reassembly_warn_state] = plot_utils.make_plot( ...
        z_vals, [], peak_oa, [], title_text, ...
        'z [m]', 'I_oa,max over pulse-frame t estimate [approx. W/m^2]', ...
        'reassembled_oa_peak_vs_z', plot_settings, ...
        'run_warn_state', reassembly_warn_state);
end

function reassembly_warn_state = emit_optional_reassembled_plots_local( ...
        diag, make_plots, io_ctx, reassembly_warn_state, reassembly_warn_phase)
% Emit the optional quick-look reassembly plots behind one final dispatcher.
    if nargin < 4 || ~isstruct(reassembly_warn_state)
        reassembly_warn_state = struct();
    end
    if ~logical(make_plots) || isempty(struct_utils.opt_struct_field(diag, 'store_z', []))
        return;
    end
    if ~exist(io_ctx.outdir, 'dir')
        mkdir(io_ctx.outdir);
    end

    z_col = diag.store_z(:);
    z_mask = isfinite(z_col);
    can_emit_z_plots = true;
    if ~any(z_mask)
        reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'reassembled_plot_skipped_no_finite_z', 'CerUPP:ReassembledPlotSkippedNoFiniteZ', ...
            'Skipping z-based reassembled plots because all store_z values are non-finite.');
        can_emit_z_plots = false;
    elseif ~isfield(diag, 'store_intens_td_oa') || isempty(diag.store_intens_td_oa)
        reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'reassembled_plot_skipped_missing_oa_trace', 'CerUPP:ReassembledPlotSkippedMissingOaTrace', ...
            ['Skipping z-based reassembled plots because store_intens_td_oa was not rebuilt ', ...
             '(for example, a restart set missing diagnostic-weight metadata for the actual physical-units map).']);
        can_emit_z_plots = false;
    end
    if ~can_emit_z_plots
        return;
    end

    oa_time_traces = diag.store_intens_td_oa(z_mask, :);
    peak_oa = NaN(sum(z_mask), 1);
    fully_finite_rows = all(isfinite(oa_time_traces), 2);
    if any(fully_finite_rows)
        peak_oa(fully_finite_rows) = max(oa_time_traces(fully_finite_rows, :), [], 2);
    end
    mixed_nonfinite_rows = any(isfinite(oa_time_traces), 2) & any(~isfinite(oa_time_traces), 2);
    if any(mixed_nonfinite_rows)
        reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'reassembled_oa_peak_mixed_nonfinite_rows', 'CerUPP:ReassembledOaPeakMixedNonfiniteRows', ...
            ['Blanking reassembled on-axis peak-vs-z points for rebuilt time traces that mix finite and ', ...
             'non-finite samples. The offline quick-look peak trace now reports only fully finite rebuilt rows.']);
    end
    reassembly_warn_state = emit_reassembled_oa_peak_plot_local( ...
        z_col(z_mask), peak_oa, diag.reassembly_metric_mode, io_ctx.outdir, ...
        reassembly_warn_state);
end

function metric_mode_text = reassembly_metric_mode_text_local(reassembly_metric_mode)
% Map compact reassembly metric labels onto one human-readable subtitle fragment.
    metric_mode_text = '';
    if ~(ischar(reassembly_metric_mode) || ...
            (isstring(reassembly_metric_mode) && isscalar(reassembly_metric_mode)))
        return;
    end
    metric_mode_key = lower(strtrim(char(reassembly_metric_mode)));
    switch metric_mode_key
        case {'n_over_nref_weighted_intensity', 'actual_physical_units_n_over_nref_weighted_intensity'}
            metric_mode_text = '(n(x,y,omega_fund)/n_ref) weighted intensity estimate';
        case 'partial_weighted_rebuild'
            metric_mode_text = 'weighted intensity estimate is only partially available across the selected checkpoints';
        case 'mixed_or_unknown'
            metric_mode_text = 'weighted intensity estimate is mixed or unavailable for the selected checkpoints';
        otherwise
            metric_mode_text = strtrim(char(reassembly_metric_mode));
    end
end

function diag = finalize_reassembly_metric_status_local(diag, file_records, selected_step_record_idx)
% Downgrade the public metric label when selected checkpoints lack rebuildable diagnostic-weight metadata.
    if ~(isstruct(diag) && isfield(diag, 'reassembly_meta') && isstruct(diag.reassembly_meta))
        return;
    end
    metric_mode = 'mixed_or_unknown';
    metric_status = 'unknown';
    weighted_metric_complete = false;
    metric_notes = {};
    if isempty(selected_step_record_idx)
        diag.reassembly_metric_mode = metric_mode;
        diag.reassembly_meta.metric_mode = metric_mode;
        diag.reassembly_meta.weighted_metric_complete = weighted_metric_complete;
        diag.reassembly_meta.metric_mode_status = metric_status;
        diag.reassembly_meta.metric_mode_notes = metric_notes;
        return;
    end

    diag_weight_ok = false(numel(selected_step_record_idx), 1);
    missing_reasons = cell(0, 1);
    for ii = 1:numel(selected_step_record_idx)
        record_idx = selected_step_record_idx(ii);
        candidate_input = struct_utils.opt_struct_field( ...
            file_records(record_idx), 'validated_candidate_input', struct());
        if isstruct(candidate_input) && isfield(candidate_input, 'diag_weight_ok')
            diag_weight_ok(ii) = logical(candidate_input.diag_weight_ok);
            if ~diag_weight_ok(ii)
                reason = struct_utils.opt_struct_field(candidate_input, 'diag_weight_reason', 'unavailable');
                missing_reasons{end+1, 1} = sprintf('%s:%s', file_records(record_idx).name, char(string(reason))); %#ok<AGROW>
            end
        else
            missing_reasons{end+1, 1} = sprintf('%s:%s', file_records(record_idx).name, 'missing_validated_diag_weight_status'); %#ok<AGROW>
        end
    end

    if all(diag_weight_ok)
        metric_mode = 'n_over_nref_weighted_intensity';
        metric_status = 'complete';
        weighted_metric_complete = true;
    elseif any(diag_weight_ok)
        metric_mode = 'partial_weighted_rebuild';
        metric_status = 'mixed';
        metric_notes = missing_reasons;
    else
        metric_mode = 'mixed_or_unknown';
        metric_status = 'missing_diag_weight_metadata';
        metric_notes = missing_reasons;
    end

    diag.reassembly_metric_mode = metric_mode;
    diag.reassembly_meta.metric_mode = metric_mode;
    diag.reassembly_meta.weighted_metric_complete = weighted_metric_complete;
    diag.reassembly_meta.metric_mode_status = metric_status;
    diag.reassembly_meta.metric_mode_notes = metric_notes;
end

function finalize_and_save_reassembled_diag_local(diag, reassembly_warn_state, reassembly_warn_owner, io_ctx)
% Finalize, save, then emit the post-save warning summary.
    diag.reassembly_warn_state = reassembly_warn_state;
    diag = finalize_diag_store_fields_local(diag);
    diag = clear_diag_store_alloc_ctx_local(diag);
    diag = clear_reassembly_grid_ref_ctx_local(diag);
    save_reassembled_diag_local(diag, io_ctx);
    if run_warn_state_utils.has_summary_content(reassembly_warn_state)
        run_warn_state_utils.emit_summary(reassembly_warn_state, reassembly_warn_owner, false);
    end
end

function [step, rebuild_meta, rebuild_shape] = rebuild_selected_payload_local( ...
        rs, checkpoint_dir, checkpoint_name, x, y, t, ...
    n_ratio_diag_xy, diag_weight_ok, diag_weight_reason, diag_weight_note, ...
    rebuild_policy)
% Rebuild one already-validated restart payload for output assembly.
    A_S = rs.state.A_S;
    [nx, ny, nt] = size(A_S);
    if numel(x) ~= nx || numel(y) ~= ny || numel(t) ~= nt
        error('assemble_diagnostics_from_restart:SelectedCheckpointGridMismatch', ...
            'Selected checkpoint %s no longer matches its x/y/t grid sizes during rebuild.', ...
            checkpoint_name);
    end
    rebuild_shape = [nx, ny, nt];
    [step, rebuild_meta] = rebuild_one_checkpoint_local( ...
        rs, checkpoint_dir, checkpoint_name, x, y, t, ...
        n_ratio_diag_xy, diag_weight_ok, diag_weight_reason, diag_weight_note, ...
        rebuild_policy);
end

function [diag, file_records, reassembly_warn_state, reassembly_issue_ledger] = ...
        rebuild_selected_reassembly_records_local( ...
            diag, file_records, selected_step_record_idx, checkpoint_dir, ...
            rebuild_policy, ...
            reassembly_warn_state, reassembly_warn_phase, ...
            reassembly_issue_ledger)
% Rebuild the selected checkpoint set during the post-selection assignment phase.
    selected_diag_specs = checkpoint_utils.diag_specs_for_rebuild_families( ...
        rebuild_policy.requested_families);
    for out_idx = 1:numel(selected_step_record_idx)
        record_idx = selected_step_record_idx(out_idx);
        checkpoint_name = file_records(record_idx).name;
        candidate_input = require_validated_reassembly_candidate_input_local( ...
            file_records(record_idx), checkpoint_name);
        [rs, x, y, t, n_ratio_diag_xy] = reuse_or_load_validated_reassembly_checkpoint_payload_local( ...
            file_records(record_idx), checkpoint_dir, checkpoint_name);
        [step, rebuild_meta] = rebuild_selected_payload_local( ...
            rs, checkpoint_dir, checkpoint_name, ...
            x, y, t, ...
            n_ratio_diag_xy, candidate_input.diag_weight_ok, ...
            candidate_input.diag_weight_reason, candidate_input.diag_weight_note, ...
            rebuild_policy);
        [file_records, reassembly_warn_state, reassembly_issue_ledger] = record_rebuild_meta_local( ...
            file_records, record_idx, checkpoint_name, rebuild_meta, ...
            reassembly_warn_state, reassembly_warn_phase, reassembly_issue_ledger);
        if isstruct(step) && isfield(step, 'store_z') && isscalar(step.store_z) && isfinite(step.store_z)
            file_records(record_idx).selected_store_z = double(step.store_z);
        end
        diag = assign_step_local(diag, step, out_idx, selected_diag_specs);
        file_records(record_idx).processed = true;
        file_records(record_idx).selected_output_slot = out_idx;
    end
end

function candidate_input = require_validated_reassembly_candidate_input_local(file_record, checkpoint_name)
% Recover the lightweight validated metadata captured during the validation pass.
    if nargin < 2 || isempty(checkpoint_name)
        checkpoint_name = '';
    end
    candidate_input = struct_utils.opt_struct_field(file_record, 'validated_candidate_input', struct());
    if ~(isstruct(candidate_input) && ...
            isfield(candidate_input, 'grid_shape') && isnumeric(candidate_input.grid_shape) && ...
            numel(candidate_input.grid_shape) == 3 && ...
            isfield(candidate_input, 'diag_weight_ok') && ...
            isfield(candidate_input, 'diag_weight_reason') && ...
            isfield(candidate_input, 'diag_weight_note'))
        error('assemble_diagnostics_from_restart:MissingValidatedCandidateInput', ...
            ['Selected checkpoint %s is missing the cached validated reassembly metadata. ', ...
             'Reassembly now requires first-pass validation metadata capture.'], ...
            checkpoint_name);
    end
end

function record = build_rebuild_provenance_record_local(code, detail, used_exact_ledger)
% Build one structured provenance record for the canonical rebuild state.
    if nargin < 1 || isempty(code)
        code = '';
    end
    if nargin < 2 || isempty(detail)
        detail = '';
    end
    if nargin < 3 || isempty(used_exact_ledger)
        used_exact_ledger = false;
    end
    record = struct( ...
        'code', char(string(code)), ...
        'detail', char(string(detail)), ...
        'used_exact_ledger', logical(used_exact_ledger));
end

function rebuild_meta = set_rebuild_provenance_local( ...
        rebuild_meta, field_name, code, detail, used_exact_ledger)
% Store one structured provenance record under rebuild_meta.provenance.
    if nargin < 4 || isempty(detail)
        detail = '';
    end
    if nargin < 5 || isempty(used_exact_ledger)
        used_exact_ledger = false;
    end
    if ~isstruct(rebuild_meta)
        rebuild_meta = struct();
    end
    if ~isfield(rebuild_meta, 'provenance') || ~isstruct(rebuild_meta.provenance)
        rebuild_meta.provenance = struct();
    end
    rebuild_meta.provenance.(field_name) = build_rebuild_provenance_record_local( ...
        code, detail, used_exact_ledger);
end

function detail = get_rebuild_provenance_detail_local(rebuild_meta, field_name, default_detail)
% Read one structured provenance detail from rebuild_meta.provenance.
% Any legacy flat-string mirrors are optional exports, not the in-core
% source of truth for restart rebuild provenance.
    if nargin < 3
        default_detail = '';
    end
    detail = char(string(default_detail));
    if ~isstruct(rebuild_meta) || ~isfield(rebuild_meta, 'provenance') || ...
            ~isstruct(rebuild_meta.provenance) || ...
            ~isfield(rebuild_meta.provenance, field_name) || ...
            ~isstruct(rebuild_meta.provenance.(field_name))
        return;
    end
    detail = char(string(struct_utils.opt_struct_field( ...
        rebuild_meta.provenance.(field_name), 'detail', detail)));
end

function rebuild_meta = set_rebuild_spectrum_provenance_local(rebuild_meta, source_tag, reason)
% Update the structured spectrum provenance.
    if nargin < 2 || isempty(source_tag)
        source_tag = '';
    end
    if nargin < 3 || isempty(reason)
        reason = '';
    end
    rebuild_meta = set_rebuild_provenance_local( ...
        rebuild_meta, 'spectrum', source_tag, reason, false);
end

function [file_records, reassembly_warn_state, reassembly_issue_ledger] = record_rebuild_meta_local( ...
    file_records, k, checkpoint_name, rebuild_meta, reassembly_warn_state, reassembly_warn_phase, reassembly_issue_ledger)
% Record rebuild-side metadata/warnings for one output checkpoint.
    if isstruct(rebuild_meta)
        file_records(k).rebuild_meta = rebuild_meta;
    else
        file_records(k).rebuild_meta = struct();
    end
    if isstruct(rebuild_meta) && isfield(rebuild_meta, 'spectrum_ok') && ~logical(rebuild_meta.spectrum_ok)
        reassembly_issue_ledger = record_reassembly_issue_local( ...
            reassembly_issue_ledger, 'spectrum_rebuild', checkpoint_name, '');
        reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
            reassembly_warn_state, reassembly_warn_phase, ...
            'restart_spectrum_rebuild_unavailable', 'CerUPP:RestartSpectrumRebuildUnavailable', ...
            ['One or more restart checkpoints could not reconstruct store_spectrum from restart-held field/grid/diagnostic-weight data. ', ...
             'First failure: %s (reason=%s).'], ...
            checkpoint_name, get_rebuild_provenance_detail_local( ...
                rebuild_meta, 'spectrum', 'unknown'));
    end
    if isstruct(rebuild_meta) && isfield(rebuild_meta, 'partial_issue_count') && ...
            (double(rebuild_meta.partial_issue_count) > 0)
        reassembly_issue_ledger = record_reassembly_issue_local( ...
            reassembly_issue_ledger, 'partial_rebuild', checkpoint_name, rebuild_meta.partial_issue_reason);
        file_records = set_reassembly_record_status_local( ...
            file_records, k, 'reassembly_detail', 'processed_partial', rebuild_meta.partial_issue_reason);
    else
        file_records = set_reassembly_record_status_local( ...
            file_records, k, 'reassembly_detail', 'processed', '');
    end
end

function issue_ledger = init_reassembly_issue_ledger_local(n_files)
% Preallocate one canonical ordered issue-entry ledger for reassembly failures/issues.
    issue_ledger = struct( ...
        'count', 0, ...
        'entries', repmat(reassembly_issue_entry_template_local(), n_files, 1));
end

function issue_ledger = record_reassembly_issue_local(issue_ledger, issue_kind, checkpoint_name, issue_reason)
% Append one reassembly issue into the canonical ordered issue ledger.
    if nargin < 4
        issue_reason = '';
    end
    issue_kind = validate_reassembly_issue_kind_local(issue_kind);
    issue_ledger.count = issue_ledger.count + 1;
    if issue_ledger.count > numel(issue_ledger.entries)
        issue_ledger.entries(issue_ledger.count, 1) = reassembly_issue_entry_template_local();
    end
    issue_ledger.entries(issue_ledger.count, 1) = struct( ...
        'kind', issue_kind, ...
        'checkpoint_name', char(string(checkpoint_name)), ...
        'reason', char(string(issue_reason)));
end

function diag = finalize_reassembly_issue_ledger_local(diag, issue_ledger)
% Derive the public diag issue-summary fields from the one canonical issue ledger.
    issue_specs = reassembly_issue_specs_local();
    for spec_idx = 1:numel(issue_specs)
        issue_spec = issue_specs(spec_idx);
        issue_entries = collect_reassembly_issue_entries_local(issue_ledger, issue_spec.kind);
        diag.(issue_spec.diag_count_field) = numel(issue_entries);
        issue_files = cell(0, 1);
        if ~isempty(issue_entries)
            issue_files = reshape({issue_entries.checkpoint_name}, [], 1);
        end
        diag.(issue_spec.diag_files_field) = issue_files;
        if ~isempty(issue_spec.diag_reasons_field)
            issue_reasons = cell(0, 1);
            if ~isempty(issue_entries)
                issue_reasons = reshape({issue_entries.reason}, [], 1);
            end
            diag.(issue_spec.diag_reasons_field) = issue_reasons;
        end
    end
end

function reassembly_warn_state = emit_batched_reassembly_issue_warnings_local( ...
    reassembly_warn_state, reassembly_warn_phase, issue_ledger)
% Emit the noisy warning families from the canonical issue ledger.
    issue_specs = reassembly_issue_specs_local();
    for spec_idx = 1:numel(issue_specs)
        issue_spec = issue_specs(spec_idx);
        if isempty(issue_spec.warn_key)
            continue;
        end
        issue_entries = collect_reassembly_issue_entries_local(issue_ledger, issue_spec.kind);
        if isempty(issue_entries)
            continue;
        end
        switch issue_spec.kind
            case 'restart_load'
                reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    reassembly_warn_state, reassembly_warn_phase, ...
                    issue_spec.warn_key, issue_spec.warn_id, ...
                    ['Skipped %d checkpoint(s) because restart_state could not be loaded. ', ...
                     'First failure: %s.'], ...
                    numel(issue_entries), issue_entries(1).checkpoint_name);
            case 'missing_restart_state'
                reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    reassembly_warn_state, reassembly_warn_phase, ...
                    issue_spec.warn_key, issue_spec.warn_id, ...
                    ['Skipped %d checkpoint(s) because restart_state was missing. ', ...
                     'First failure: %s.'], ...
                    numel(issue_entries), issue_entries(1).checkpoint_name);
            case 'partial_rebuild'
                first_reason = issue_entries(1).reason;
                if ~ischar(first_reason) || isempty(first_reason)
                    first_reason = 'n/a';
                end
                reassembly_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    reassembly_warn_state, reassembly_warn_phase, ...
                    issue_spec.warn_key, issue_spec.warn_id, ...
                    ['Reconstructed %d checkpoint(s) with partial diagnostic issues. ', ...
                     'First affected checkpoint: %s (reason=%s).'], ...
                    numel(issue_entries), issue_entries(1).checkpoint_name, first_reason);
        end
    end
end

function issue_specs = reassembly_issue_specs_local()
% Canonical spec table for private reassembly issue kinds and their derived public views.
    issue_specs = struct( ...
        'kind', {'restart_load', 'missing_restart_state', 'spectrum_rebuild', 'partial_rebuild'}, ...
        'diag_count_field', {'restart_load_failure_count', 'missing_restart_state_count', ...
                             'spectrum_rebuild_failure_count', 'partial_rebuild_count'}, ...
        'diag_files_field', {'restart_load_failure_files', 'missing_restart_state_files', ...
                             'spectrum_rebuild_failure_files', 'partial_rebuild_issue_files'}, ...
        'diag_reasons_field', {'', '', '', 'partial_rebuild_issue_reasons'}, ...
        'warn_key', {'restart_checkpoint_load_failed_batch', 'restart_missing_state_batch', '', ...
                     'restart_partial_rebuild_batch'}, ...
        'warn_id', {'CerUPP:RestartCheckpointLoadFailed', 'CerUPP:MissingRestartState', '', ...
                    'CerUPP:RestartPartialDiagnosticRebuild'});
end

function issue_kind = validate_reassembly_issue_kind_local(issue_kind)
% Validate one reassembly issue kind against the canonical private spec table.
    issue_kind = char(string(issue_kind));
    issue_specs = reassembly_issue_specs_local();
    valid_kinds = {issue_specs.kind};
    if ~ismember(issue_kind, valid_kinds)
        error('assemble_diagnostics_from_restart:UnknownReassemblyIssueKind', ...
            'Unknown reassembly issue kind "%s".', issue_kind);
    end
end

function issue_entries = collect_reassembly_issue_entries_local(issue_ledger, issue_kind)
% Collect one issue family from the canonical ordered ledger.
    issue_kind = validate_reassembly_issue_kind_local(issue_kind);
    if issue_ledger.count < 1
        issue_entries = repmat(reassembly_issue_entry_template_local(), 0, 1);
        return;
    end
    entries = issue_ledger.entries(1:issue_ledger.count);
    kind_mask = strcmp({entries.kind}, issue_kind);
    issue_entries = entries(kind_mask);
    if isempty(issue_entries)
        issue_entries = repmat(reassembly_issue_entry_template_local(), 0, 1);
    end
end

function issue_entry = reassembly_issue_entry_template_local()
% Empty template for one reassembly issue ledger entry.
    issue_entry = struct( ...
        'kind', '', ...
        'checkpoint_name', '', ...
        'reason', '');
end

function diag = init_diag_store_local(diag, nsave, nx, ny, nt)
% Record the canonical output-store shape; fields are allocated lazily on first assignment.
    diag.reassembly_store_alloc_ctx = struct( ...
        'nsave', nsave, ...
        'nx', nx, ...
        'ny', ny, ...
        'nt', nt);
end

function [step, rebuild_meta] = rebuild_one_checkpoint_local( ...
    rs, checkpoint_dir, checkpoint_name, x, y, t, ...
    n_ratio_diag_xy, diag_weight_ok, diag_weight_reason, diag_weight_note, ...
    rebuild_policy)
% Reconstruct one storage slice from restart payload fields.
A_S = rs.state.A_S;
[nx, ny, nt] = size(A_S);

step = struct();
rebuild_meta = struct( ...
    'spectrum_ok', false, ...
    'provenance_schema_version', double(1), ...
    'provenance', struct( ...
        'spectrum', build_rebuild_provenance_record_local('not_attempted', '', false), ...
        'nla_loss_applied', build_rebuild_provenance_record_local('not_rebuilt', '', false), ...
        'store_j_mpa', build_rebuild_provenance_record_local('not_rebuilt', '', false), ...
        'store_drho_ofi_xz', build_rebuild_provenance_record_local('not_rebuilt', '', false), ...
        'store_drho_aval_xz', build_rebuild_provenance_record_local('not_rebuilt', '', false)), ...
    'store_inv_vg_source', '', ...
    'partial_issue_count', 0, ...
    'partial_issue_reason', '');
partial_issues = {};
if isfield(rs.progress, 'z_post_step_m') && isfinite(rs.progress.z_post_step_m)
    step.store_z = double(rs.progress.z_post_step_m);
elseif isfield(rs.progress, 'z_curr') && isfinite(rs.progress.z_curr)
    step.store_z = double(rs.progress.z_curr);
end
[step.store_inv_vg, rebuild_meta.store_inv_vg_source, store_inv_vg_reason] = resolve_restart_store_inv_vg_local( ...
    rs, checkpoint_dir, checkpoint_name);
if ~isempty(store_inv_vg_reason)
    partial_issues{end+1} = sprintf('store_inv_vg:%s', store_inv_vg_reason); %#ok<AGROW>
end

[delta_t, delta_t_ok, delta_t_reason] = infer_delta_t_local(t);
[fluence_use_parseval] = resolve_restart_fluence_use_parseval_local(rs);
parseval_time_grid_ok = [];
if logical(fluence_use_parseval) && delta_t_ok
    parseval_time_grid_ok = filament_diagnostics_utils.time_grid_supports_parseval_fluence(t, delta_t);
end
[rebuild_flags] = resolve_restart_rebuild_output_flags_local(rs, rebuild_policy);
rebuild_core = logical(rebuild_policy.core);

[~, ix_axis0] = min(abs(x));
[~, iy_axis0] = min(abs(y));

aw_xyw = [];
af_mag2 = [];
weighted_a_ssf_mag2 = [];
intens_s = real(A_S .* conj(A_S));
intens_diag = [];
band_ctx = init_restart_band_mask_ctx_local(nt);
masks = band_ctx.masks;
has_masks = band_ctx.has_masks;
f_fund_xy = [];
if rebuild_core
    step.store_imax_code_oa = max(intens_s(ix_axis0, iy_axis0, :), [], 'all', 'omitnan');
    step.store_imax_code_bc = NaN;
end
beamcenter_sample_ok = false;
ix_bc = NaN;
iy_bc = NaN;
fluence_summary = struct( ...
    'total', NaN, ...
    'centroid_x', NaN, ...
    'centroid_y', NaN, ...
    'peak_x', NaN, ...
    'peak_y', NaN, ...
    'ix_beamcenter', NaN, ...
    'iy_beamcenter', NaN, ...
    'x_beamcenter', NaN, ...
    'y_beamcenter', NaN, ...
    'method_code', NaN);
if logical(diag_weight_ok)
    intens_diag = n_ratio_diag_xy .* intens_s;
    if rebuild_flags.bands_rgb
        band_ctx = build_band_masks_local(rs, nt, checkpoint_name);
    end
    masks = band_ctx.masks;
    has_masks = band_ctx.has_masks;
    if rebuild_flags.bands_rgb && ~has_masks
        if isfield(band_ctx, 'mask_skip_reason') && ischar(band_ctx.mask_skip_reason) && ...
                ~isempty(band_ctx.mask_skip_reason)
            partial_issues{end+1} = sprintf('bands_rgb:%s', band_ctx.mask_skip_reason); %#ok<AGROW>
        else
            partial_issues{end+1} = 'bands_rgb:band_masks_unavailable_for_restart_rebuild'; %#ok<AGROW>
        end
    end

    % Reassemble fluence using the same spatial weighting and fluence-method policy as the live driver.
    if logical(fluence_use_parseval)
        aw_xyw = ensure_restart_spectral_field_local(aw_xyw, A_S);
    end
    total_fluence_xy = build_restart_weighted_fluence_from_masked_spectrum_local( ...
        aw_xyw, n_ratio_diag_xy, t, delta_t, fluence_use_parseval, intens_diag, [], [], parseval_time_grid_ok);
    intens_diag_2_d = reshape(intens_diag, [], nt);
    fluence_summary = storage_support.summarize_fluence_map(x, y, total_fluence_xy);
    ix_bc = fluence_summary.ix_beamcenter;
    iy_bc = fluence_summary.iy_beamcenter;
    beamcenter_sample_ok = isscalar(ix_bc) && isscalar(iy_bc) && ...
        isfinite(ix_bc) && isfinite(iy_bc) && ...
        (ix_bc >= 1) && (ix_bc <= nx) && ...
        (iy_bc >= 1) && (iy_bc <= ny) && ...
        (ix_bc == round(ix_bc)) && (iy_bc == round(iy_bc));
    if rebuild_core
        step.store_fluence_xy = total_fluence_xy;
        step.store_intens_td = squeeze(trapz(x, trapz(y, intens_diag, 2), 1)).';
        step.store_intens_td_oa = squeeze(intens_diag(ix_axis0, iy_axis0, :)).';
        step.store_intens_td_maxperp = max(intens_diag_2_d, [], 1);
        [step.store_diameter_total, diameter_total_issue] = ...
            rebuild_restart_beamcenter_tracked_diameter_local( ...
            x, y, total_fluence_xy, ix_bc, iy_bc);
        if ~isempty(diameter_total_issue)
            partial_issues{end+1} = sprintf('store_diameter_total:%s', diameter_total_issue); %#ok<AGROW>
        end
        step.store_beamcenter_ix = ix_bc;
        step.store_beamcenter_iy = iy_bc;
        step.store_beamcenter_x = fluence_summary.x_beamcenter;
        step.store_beamcenter_y = fluence_summary.y_beamcenter;
        step.store_beamcenter_method_code = fluence_summary.method_code;
        step.store_intens_td_bc = nan(1, nt, 'like', real(intens_diag(1)));
        if beamcenter_sample_ok
            step.store_intens_td_bc = squeeze(intens_diag(ix_bc, iy_bc, :)).';
            step.store_imax_code_bc = max(intens_s(ix_bc, iy_bc, :), [], 'all', 'omitnan');
        end
    end
else
    if ~(ischar(diag_weight_reason) && ~isempty(diag_weight_reason))
        diag_weight_reason = 'unavailable';
    end
    partial_issues{end+1} = sprintf('diag_weight:%s', diag_weight_reason); %#ok<AGROW>
    if ischar(diag_weight_note) && ~isempty(diag_weight_note)
        partial_issues{end+1} = diag_weight_note; %#ok<AGROW>
    end
end
if rebuild_core
    step.store_imax_code_maxperp = max(intens_s(:), [], 'omitnan');
end
if rebuild_core && isfield(rs.medium, 'core_idx') && ~isempty(rs.medium.core_idx)
    intens_s_2_d = reshape(intens_s, [], nt);
    [core_idx_valid, core_idx_ok, core_idx_reason] = ...
        validate_restart_core_idx_local(rs, size(intens_s_2_d, 1), []);
    if core_idx_ok
        timedom_intensity_maxperp_kerr = max(intens_s_2_d(core_idx_valid, :), [], 1);
        step.store_imax_code_maxperp_kerr = max(timedom_intensity_maxperp_kerr, [], 'omitnan');
    elseif ~isempty(core_idx_reason)
        partial_issues{end+1} = sprintf('store_imax_code_maxperp_kerr:%s', core_idx_reason); %#ok<AGROW>
    end
end

if rebuild_flags.bands_rgb && has_masks
    aw_xyw = ensure_restart_spectral_field_local(aw_xyw, A_S);
    band_masks_store = {band_ctx.vis_3d};
    band_requests_store = struct('fluence', true, 'td_oa', true, 'td_bc', true, 'td_maxperp', true);
    idx_visible_band = 1;
    idx_fund_band = 0;
    idx_red_band = 0;
    idx_green_band = 0;
    idx_blue_band = 0;
    if masks.has_fund_mask
        idx_fund_band = numel(band_masks_store) + 1;
        band_masks_store{idx_fund_band} = band_ctx.fund_3d; %#ok<AGROW>
        band_requests_store(idx_fund_band) = struct( ... %#ok<AGROW>
            'fluence', true, 'td_oa', true, 'td_bc', true, 'td_maxperp', true);
    end
    if rebuild_flags.rgb_history
        idx_red_band = numel(band_masks_store) + 1;
        band_masks_store{idx_red_band} = band_ctx.red_3d; %#ok<AGROW>
        band_requests_store(idx_red_band) = struct( ... %#ok<AGROW>
            'fluence', true, 'td_oa', false, 'td_bc', false, 'td_maxperp', false);
        idx_green_band = numel(band_masks_store) + 1;
        band_masks_store{idx_green_band} = band_ctx.green_3d; %#ok<AGROW>
        band_requests_store(idx_green_band) = struct( ... %#ok<AGROW>
            'fluence', true, 'td_oa', false, 'td_bc', false, 'td_maxperp', false);
        idx_blue_band = numel(band_masks_store) + 1;
        band_masks_store{idx_blue_band} = band_ctx.blue_3d; %#ok<AGROW>
        band_requests_store(idx_blue_band) = struct( ... %#ok<AGROW>
            'fluence', true, 'td_oa', false, 'td_bc', false, 'td_maxperp', false);
    end
    band_mask_stack = cat(4, band_masks_store{:});
    if numel(band_masks_store) == 1
        band_mask_stack = reshape(band_mask_stack, ...
            size(band_masks_store{1}, 1), size(band_masks_store{1}, 2), size(band_masks_store{1}, 3), 1);
    end
    [band_fluence_xy, band_td_oa, band_td_bc, band_td_maxperp] = ...
        filament_diagnostics_utils.build_multi_band_time_diagnostics( ...
            aw_xyw, band_mask_stack, n_ratio_diag_xy, ...
            t, delta_t, fluence_use_parseval, ix_axis0, iy_axis0, ...
            ix_bc, iy_bc, band_requests_store, parseval_time_grid_ok, []);

    step.store_fluence_xy_visible = band_fluence_xy(:, :, idx_visible_band);
    step.store_intens_td_oa_vis = band_td_oa(idx_visible_band, :);
    step.store_intens_td_bc_vis = band_td_bc(idx_visible_band, :);
    step.store_intens_td_maxperp_vis = band_td_maxperp(idx_visible_band, :);
    step.store_fpeak_vis = max(step.store_fluence_xy_visible(:), [], 'omitnan');

    if idx_fund_band > 0
        f_fund_xy = band_fluence_xy(:, :, idx_fund_band);
        step.store_intens_td_oa_fund = band_td_oa(idx_fund_band, :);
        step.store_intens_td_bc_fund = band_td_bc(idx_fund_band, :);
        step.store_intens_td_maxperp_fund = band_td_maxperp(idx_fund_band, :);
        step.store_fpeak_fund = max(f_fund_xy(:), [], 'omitnan');
    end

    if idx_red_band > 0
        step.store_rgb_fluence_r = band_fluence_xy(:, :, idx_red_band);
        step.store_rgb_fluence_g = band_fluence_xy(:, :, idx_green_band);
        step.store_rgb_fluence_b = band_fluence_xy(:, :, idx_blue_band);
        step.final_rgb_fluence_r = step.store_rgb_fluence_r;
        step.final_rgb_fluence_g = step.store_rgb_fluence_g;
        step.final_rgb_fluence_b = step.store_rgb_fluence_b;
    end

    tmp_side = squeeze(trapz(y, step.store_fluence_xy_visible, 2));
    if isvector(tmp_side) && (numel(tmp_side) == nx)
        step.store_side_vis_xz = tmp_side(:);
    end
end
if has_masks && logical(masks.has_fund_mask)
    if isempty(f_fund_xy)
        aw_xyw = ensure_restart_spectral_field_local(aw_xyw, A_S);
        f_fund_xy = build_restart_weighted_fluence_from_masked_spectrum_local( ...
            aw_xyw .* band_ctx.fund_3d, n_ratio_diag_xy, ...
            t, delta_t, fluence_use_parseval, [], [], [], parseval_time_grid_ok);
    end
    [step.store_diameter_fund, diameter_fund_issue] = rebuild_restart_beamcenter_tracked_diameter_local( ...
        x, y, f_fund_xy, ix_bc, iy_bc);
    if ~isempty(diameter_fund_issue)
        partial_issues{end+1} = sprintf('store_diameter_fund:%s', diameter_fund_issue); %#ok<AGROW>
    end
elseif logical(diag_weight_ok)
    if ischar(masks.fund_skip_reason) && ~isempty(masks.fund_skip_reason)
        partial_issues{end+1} = sprintf( ...
            'store_diameter_fund:fund_mask_unavailable_for_restart_rebuild:%s', ...
            masks.fund_skip_reason); %#ok<AGROW>
    elseif ~has_masks
        partial_issues{end+1} = 'store_diameter_fund:band_masks_unavailable_for_restart_rebuild'; %#ok<AGROW>
    else
        partial_issues{end+1} = 'store_diameter_fund:fund_mask_unavailable_for_restart_rebuild'; %#ok<AGROW>
    end
end

if rebuild_core && logical(diag_weight_ok) && delta_t_ok
    aw_xyw = ensure_restart_spectral_field_local(aw_xyw, A_S);
    [af_mag2, weighted_a_ssf_mag2] = ensure_restart_weighted_spectral_density_local( ...
        af_mag2, weighted_a_ssf_mag2, aw_xyw, n_ratio_diag_xy, nx, ny);
    spectral_fluence_density_scale = delta_t^2 / (2*pi);
    step.store_spectral_line_oa = spectral_fluence_density_scale .* ...
        reshape(weighted_a_ssf_mag2(ix_axis0, iy_axis0, :), 1, []);
    if beamcenter_sample_ok
        step.store_spectral_line_bc = spectral_fluence_density_scale .* ...
            reshape(weighted_a_ssf_mag2(ix_bc, iy_bc, :), 1, []);
    else
        step.store_spectral_line_bc = nan(1, nt, 'like', real(A_S(1)));
    end
    step.store_spectral_max_xy = spectral_fluence_density_scale .* ...
        reshape(max(max(weighted_a_ssf_mag2, [], 1), [], 2), 1, []);
end

if rebuild_flags.full_spectrum
    aw_xyw = ensure_restart_spectral_field_local(aw_xyw, A_S);
    step.store_spectral_field = aw_xyw;
    if logical(diag_weight_ok) && delta_t_ok
        [af_mag2, weighted_a_ssf_mag2] = ensure_restart_weighted_spectral_density_local( ...
            af_mag2, weighted_a_ssf_mag2, aw_xyw, n_ratio_diag_xy, nx, ny);
        step.store_spectral_intens = weighted_a_ssf_mag2 * (delta_t^2 / (2*pi));
    elseif ~delta_t_ok
        partial_issues{end+1} = sprintf('store_spectral_intens:%s', delta_t_reason); %#ok<AGROW>
    end
end

if rebuild_core && logical(diag_weight_ok)
    aw_xyw = ensure_restart_spectral_field_local(aw_xyw, A_S);
    [af_mag2, weighted_a_ssf_mag2] = ensure_restart_weighted_spectral_density_local( ...
        af_mag2, weighted_a_ssf_mag2, aw_xyw, n_ratio_diag_xy, nx, ny);
end
if rebuild_core
    [step.store_spectrum, spectrum_status] = rebuild_store_spectrum_local( ...
        weighted_a_ssf_mag2, x, y, delta_t, delta_t_ok, delta_t_reason, ...
        diag_weight_ok, diag_weight_reason);
    rebuild_meta.spectrum_ok = logical(spectrum_status.ok);
    rebuild_meta = set_rebuild_spectrum_provenance_local( ...
        rebuild_meta, spectrum_status.source_tag, spectrum_status.reason);
end

s_tot = struct_utils.opt_struct_field(fluence_summary, 'total', NaN);
xc = struct_utils.opt_struct_field(fluence_summary, 'centroid_x', NaN);
yc = struct_utils.opt_struct_field(fluence_summary, 'centroid_y', NaN);
xpk = struct_utils.opt_struct_field(fluence_summary, 'peak_x', NaN);
ypk = struct_utils.opt_struct_field(fluence_summary, 'peak_y', NaN);
rmean_fluence = struct_utils.opt_struct_field(fluence_summary, 'rmean_fluence', NaN);
if rebuild_core
    if isfinite(s_tot) && (s_tot > 0) && isfinite(rmean_fluence)
        step.store_rmean_fluence = rmean_fluence;
    end
    if isfinite(s_tot) && (s_tot > 0) && isfinite(xc) && isfinite(yc)
        step.store_centroid_x = xc;
        step.store_centroid_y = yc;
        step.store_centroid_r = hypot(xc, yc);
    end
    if isfinite(xpk) && isfinite(ypk)
        step.store_peak_x = xpk;
        step.store_peak_y = ypk;
        step.store_peak_r = hypot(xpk, ypk);
    end
end
if isstruct(masks) && ~masks.has_fund_mask && ischar(masks.fund_skip_reason) && ~isempty(masks.fund_skip_reason)
    partial_issues{end+1} = sprintf('fund_mask:%s', masks.fund_skip_reason); %#ok<AGROW>
end
if rebuild_flags.plasma_nla
nla_book = [];
if isfield(rs.state, 'nla_book') && isstruct(rs.state.nla_book)
    nla_book = rs.state.nla_book;
end
plasma_book = [];
if isfield(rs.state, 'plasma_book') && isstruct(rs.state.plasma_book)
    plasma_book = rs.state.plasma_book;
end
nla_loss_exact_field = opt_restart_book_field_local(nla_book, 'loss_rate_applied_core');
has_exact_nla_loss_field = ~isempty(nla_loss_exact_field);
has_j_mpa_field = ...
    (isfield(rs.state, 'j_mpa') && ~isempty(rs.state.j_mpa)) || ...
    (isfield(rs.state, 'J_mpa') && ~isempty(rs.state.J_mpa));
nla_active = has_j_mpa_field || has_exact_nla_loss_field;
plasma_active = (isfield(rs.state, 'rho') && ~isempty(rs.state.rho)) || ...
    (isfield(rs.state, 'rhs_plasma') && ~isempty(rs.state.rhs_plasma));
diag_xy_scatter_ws = [];
[rho_core, rho_core_idx, rho_core_ok] = get_core_td_rows_local( ...
    struct_utils.opt_struct_field(rs.state, 'rho', []), rs, nx, ny, nt);
if rho_core_ok
    rho_max_core = max(rho_core, [], 2);
    rho_int_core = trapz(t, rho_core, 2);
    rho_late_core = rho_core(:, end);
    [step.store_max_rho, diag_xy_scatter_ws] = propagation_support.scatter_core_vec_to_xy( ...
        rho_max_core, rho_core_idx, nx, ny, rho_max_core, diag_xy_scatter_ws);
    [step.store_rho_int, diag_xy_scatter_ws] = propagation_support.scatter_core_vec_to_xy( ...
        rho_int_core, rho_core_idx, nx, ny, rho_int_core, diag_xy_scatter_ws);
    [step.store_rho_late, diag_xy_scatter_ws] = propagation_support.scatter_core_vec_to_xy( ...
        rho_late_core, rho_core_idx, nx, ny, rho_late_core, diag_xy_scatter_ws);
else
    [rho_full, rho_ok, rho_reason] = expand_core_or_full_td_local(struct_utils.opt_struct_field(rs.state, 'rho', []), ...
        rs, nx, ny, nt, 0);
    if rho_ok
        step.store_max_rho = max(rho_full, [], 3);
        step.store_rho_int = trapz(t, rho_full, 3);
        step.store_rho_late = rho_full(:, :, end);
    elseif isfield(rs.state, 'rho') && ~isempty(rs.state.rho) && ~isempty(rho_reason)
        partial_issues{end+1} = sprintf('rho:%s', rho_reason); %#ok<AGROW>
    end
end
if isfield(step, 'store_rho_int') && ~isempty(step.store_rho_int)
    step.store_rho_int_maxperp = squeeze(max(max(step.store_rho_int, [], 1), [], 2));
end
if isfield(step, 'store_max_rho') && ~isempty(step.store_max_rho)
    step.store_max_rho_maxperp = squeeze(max(max(step.store_max_rho, [], 1), [], 2));
end

[rhs_core, rhs_core_idx, rhs_core_ok] = get_core_td_rows_local( ...
    struct_utils.opt_struct_field(rs.state, 'rhs_plasma', []), rs, nx, ny, nt);
if rhs_core_ok
    rhs_int_core = trapz(t, abs(rhs_core), 2);
    [step.store_rhs_plasma, diag_xy_scatter_ws] = propagation_support.scatter_core_vec_to_xy( ...
        rhs_int_core, rhs_core_idx, nx, ny, rhs_int_core, diag_xy_scatter_ws);
else
    [rhs_full, rhs_ok, rhs_reason] = expand_core_or_full_td_local(struct_utils.opt_struct_field(rs.state, 'rhs_plasma', []), ...
        rs, nx, ny, nt, 0);
    if rhs_ok
        step.store_rhs_plasma = trapz(t, abs(rhs_full), 3);
    elseif isfield(rs.state, 'rhs_plasma') && ~isempty(rs.state.rhs_plasma) && ~isempty(rhs_reason)
        partial_issues{end+1} = sprintf('rhs_plasma:%s', rhs_reason); %#ok<AGROW>
    end
end

[nla_loss_core, nla_loss_core_idx, nla_loss_core_ok] = get_core_td_rows_local( ...
    nla_loss_exact_field, rs, nx, ny, nt);
[nla_exact_valid_core, nla_exact_valid_core_idx, nla_exact_valid_core_ok, nla_exact_valid_core_reason] = ...
    get_exact_valid_core_rows_local(nla_book, rs, nx, ny, nt);
nla_exact_ready = false;
if has_exact_nla_loss_field && nla_loss_core_ok && nla_exact_valid_core_ok && ...
        isequal(nla_loss_core_idx, nla_exact_valid_core_idx)
    nla_exact_invalid_count = nnz(~nla_exact_valid_core(:));
    if nla_exact_invalid_count > 0
        partial_issues{end+1} = sprintf( ...
            'nla_book.loss_rate_applied_core:masked_invalid_exact_cells_unusable_%d', nla_exact_invalid_count); %#ok<AGROW>
        rebuild_meta = set_rebuild_provenance_local( ...
            rebuild_meta, 'nla_loss_applied', ...
            'exact_applied_ledger', 'masked_unusable', false);
    else
        nla_loss_int_core = trapz(t, nla_loss_core, 2);
        [step.store_nla_loss_applied, diag_xy_scatter_ws] = propagation_support.scatter_core_vec_to_xy( ...
            nla_loss_int_core, nla_loss_core_idx, nx, ny, nla_loss_int_core, diag_xy_scatter_ws);
        if logical(diag_weight_ok)
            step.store_nla_loss_applied = n_ratio_diag_xy .* step.store_nla_loss_applied;
        end
        step.store_mpa_d_e_dz = trapz(x, trapz(y, step.store_nla_loss_applied, 2), 1);
        rebuild_meta = set_rebuild_provenance_local( ...
            rebuild_meta, 'nla_loss_applied', ...
            'exact_applied_ledger', '', true);
        nla_exact_ready = true;
    end
else
    [nla_loss_full, nla_loss_ok, nla_loss_reason] = expand_core_or_full_td_local( ...
        nla_loss_exact_field, rs, nx, ny, nt, 0);
    [nla_exact_valid_full, nla_exact_valid_ok, nla_exact_valid_reason, nla_exact_invalid_count] = ...
        expand_exact_valid_core_local(nla_book, rs, nx, ny, nt);
    if has_exact_nla_loss_field && nla_loss_ok && nla_exact_valid_ok
        if nla_exact_invalid_count > 0
            partial_issues{end+1} = sprintf( ...
                'nla_book.loss_rate_applied_core:masked_invalid_exact_cells_unusable_%d', nla_exact_invalid_count); %#ok<AGROW>
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'nla_loss_applied', ...
                'exact_applied_ledger', 'masked_unusable', false);
        else
            step.store_nla_loss_applied = trapz(t, nla_loss_full, 3);
            if logical(diag_weight_ok)
                step.store_nla_loss_applied = n_ratio_diag_xy .* step.store_nla_loss_applied;
            end
            step.store_mpa_d_e_dz = trapz(x, trapz(y, step.store_nla_loss_applied, 2), 1);
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'nla_loss_applied', ...
                'exact_applied_ledger', '', true);
            nla_exact_ready = true;
        end
    elseif has_exact_nla_loss_field && ...
            (~isempty(nla_loss_reason) || ~nla_exact_valid_ok)
        partial_issues{end+1} = sprintf('nla_book.loss_rate_applied_core:%s', ...
            join_issue_reasons_local(nla_loss_reason, nla_exact_valid_core_reason, nla_exact_valid_reason)); %#ok<AGROW>
        rebuild_meta = set_rebuild_provenance_local( ...
            rebuild_meta, 'nla_loss_applied', ...
            'exact_applied_ledger', 'unusable', false);
    elseif nla_active
        partial_issues{end+1} = 'nla_book:missing_exact_nla_ledger'; %#ok<AGROW>
        rebuild_meta = set_rebuild_provenance_local( ...
            rebuild_meta, 'nla_loss_applied', ...
            'missing_exact_applied_ledger', '', false);
    end
end

if nla_exact_ready && isfield(step, 'store_nla_loss_applied') && ~isempty(step.store_nla_loss_applied)
    rebuild_meta = set_rebuild_provenance_local( ...
        rebuild_meta, 'store_j_mpa', ...
        'not_rebuilt_from_exact_applied_ledger', '', false);
    partial_issues{end+1} = ...
        'store_j_mpa:pre_nla_model_proxy_not_rebuilt_from_exact_applied_ledger'; %#ok<AGROW>
elseif nla_active
    rebuild_meta = set_rebuild_provenance_local( ...
        rebuild_meta, 'store_j_mpa', ...
        'not_rebuilt_without_exact_nla_loss', '', false);
    partial_issues{end+1} = 'store_j_mpa:skipped_without_exact_nla_loss'; %#ok<AGROW>
    if ~isfield(step, 'store_mpa_d_e_dz')
        partial_issues{end+1} = 'store_mpa_d_e_dz:skipped_without_exact_nla_loss'; %#ok<AGROW>
    end
end

[mpa_rhs_core, mpa_rhs_core_idx, mpa_rhs_core_ok] = get_core_td_rows_local( ...
    struct_utils.opt_struct_field(rs.state, 'mpa_rhs_mag', []), rs, nx, ny, nt);
if nla_active && mpa_rhs_core_ok
    mpa_rhs_int_core = trapz(t, real(mpa_rhs_core), 2);
    [step.store_j_mpa_rhs_mag, diag_xy_scatter_ws] = propagation_support.scatter_core_vec_to_xy( ...
        mpa_rhs_int_core, mpa_rhs_core_idx, nx, ny, mpa_rhs_int_core, diag_xy_scatter_ws);
else
    [mpa_rhs_full, mpa_rhs_ok, mpa_rhs_reason] = expand_core_or_full_td_local( ...
        struct_utils.opt_struct_field(rs.state, 'mpa_rhs_mag', []), rs, nx, ny, nt, 0);
    if nla_active && mpa_rhs_ok
        step.store_j_mpa_rhs_mag = trapz(t, real(mpa_rhs_full), 3);
    elseif nla_active && isfield(rs.state, 'mpa_rhs_mag') && ~isempty(rs.state.mpa_rhs_mag) && ~isempty(mpa_rhs_reason)
        partial_issues{end+1} = sprintf('mpa_rhs_mag:%s', mpa_rhs_reason); %#ok<AGROW>
    end
end

[plasma_field_loss_core, plasma_field_loss_core_idx, plasma_field_loss_core_ok, plasma_field_loss_reason] = ...
    get_core_vec_local( ...
        opt_restart_book_field_local(plasma_book, 'field_energy_drop_solver_timeint_core'), ...
        rs, nx, ny);
if plasma_active && plasma_field_loss_core_ok
    [plasma_field_loss_xy, ~] = propagation_support.scatter_core_vec_to_xy( ...
        plasma_field_loss_core, plasma_field_loss_core_idx, nx, ny, plasma_field_loss_core, diag_xy_scatter_ws);
    plasma_field_loss_xy = n_ratio_diag_xy .* plasma_field_loss_xy;
    step.store_plasma_field_d_e_dz = trapz(x, trapz(y, plasma_field_loss_xy, 2), 1);
else
    [plasma_field_drop_core, plasma_field_drop_core_idx, plasma_field_drop_core_ok] = get_core_td_rows_local( ...
        opt_restart_book_field_local(plasma_book, 'field_energy_drop_solver_core'), rs, nx, ny, nt);
    if plasma_active && plasma_field_drop_core_ok
        plasma_field_loss_core = trapz(t, plasma_field_drop_core, 2);
        [plasma_field_loss_xy, ~] = propagation_support.scatter_core_vec_to_xy( ...
            plasma_field_loss_core, plasma_field_drop_core_idx, nx, ny, plasma_field_loss_core, diag_xy_scatter_ws);
        plasma_field_loss_xy = n_ratio_diag_xy .* plasma_field_loss_xy;
        step.store_plasma_field_d_e_dz = trapz(x, trapz(y, plasma_field_loss_xy, 2), 1);
    else
        [plasma_field_drop_full, plasma_field_drop_ok, plasma_field_drop_reason] = expand_core_or_full_td_local( ...
        opt_restart_book_field_local(plasma_book, 'field_energy_drop_solver_core'), rs, nx, ny, nt, 0);
        if plasma_active && plasma_field_drop_ok
            plasma_field_loss_xy = trapz(t, plasma_field_drop_full, 3);
            plasma_field_loss_xy = n_ratio_diag_xy .* plasma_field_loss_xy;
            step.store_plasma_field_d_e_dz = trapz(x, trapz(y, plasma_field_loss_xy, 2), 1);
        elseif plasma_active && isstruct(plasma_book) && ~isempty(opt_restart_book_field_local(plasma_book, 'field_energy_drop_solver_core')) && ...
                ~isempty(plasma_field_drop_reason)
            partial_issues{end+1} = sprintf('plasma_book.field_energy_drop_solver_core:%s', plasma_field_drop_reason);
        elseif plasma_active && isstruct(plasma_book) && ...
                ~isempty(opt_restart_book_field_local(plasma_book, 'field_energy_drop_solver_timeint_core')) && ...
                ~isempty(plasma_field_loss_reason)
            partial_issues{end+1} = sprintf('plasma_book.field_energy_drop_solver_timeint_core:%s', plasma_field_loss_reason);
        elseif plasma_active && isempty(plasma_book)
            partial_issues{end+1} = 'plasma_book:missing_field_energy_ledger';
        end
    end
end

[dt_row, dt_ok, dt_reason] = infer_restart_dt_row_local(rs, t, nt, real(A_S(1)));
[drho_ofi_core, drho_ofi_core_idx, drho_ofi_core_ok] = get_core_td_rows_local( ...
    opt_restart_book_field_local(plasma_book, 'drho_ofi_applied'), rs, nx, ny, nt);
[drho_aval_core, drho_aval_core_idx, drho_aval_core_ok] = get_core_td_rows_local( ...
    opt_restart_book_field_local(plasma_book, 'drho_aval_applied'), rs, nx, ny, nt);
[plasma_exact_valid_core, plasma_exact_valid_core_idx, plasma_exact_valid_core_ok, plasma_exact_valid_core_reason] = ...
    get_exact_valid_core_rows_local(plasma_book, rs, nx, ny, nt);
if plasma_active && dt_ok && drho_ofi_core_ok && plasma_exact_valid_core_ok && ...
        isequal(drho_ofi_core_idx, plasma_exact_valid_core_idx)
    plasma_exact_invalid_count = nnz(~plasma_exact_valid_core(:));
    if plasma_exact_invalid_count > 0
        partial_issues{end+1} = sprintf( ...
            'plasma_book.drho_ofi_applied:masked_invalid_exact_cells_unusable_%d', plasma_exact_invalid_count); %#ok<AGROW>
        rebuild_meta = set_rebuild_provenance_local( ...
            rebuild_meta, 'store_drho_ofi_xz', ...
            'exact_applied_ledger', 'masked_unusable', false);
    else
        ofi_rate_core = applied_increment_to_rate_local(drho_ofi_core, dt_row);
        [ofi_axis_rows, ofi_axis_ok, ofi_axis_reason] = extract_core_td_axis_rows_local( ...
            ofi_rate_core, drho_ofi_core_idx, nx, ny, iy_axis0, 0);
        if ofi_axis_ok
            step.store_drho_ofi_xz = max(real(ofi_axis_rows), [], 2);
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'store_drho_ofi_xz', ...
                'exact_applied_ledger', '', true);
        elseif ~isempty(ofi_axis_reason)
            partial_issues{end+1} = sprintf('plasma_book.drho_ofi_applied:%s', ofi_axis_reason); %#ok<AGROW>
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'store_drho_ofi_xz', ...
                'exact_applied_ledger', ofi_axis_reason, false);
        end
    end
else
    [drho_ofi_full, drho_ofi_ok, drho_ofi_reason] = expand_core_or_full_td_local( ...
        opt_restart_book_field_local(plasma_book, 'drho_ofi_applied'), rs, nx, ny, nt, 0);
    [plasma_exact_valid_full, plasma_exact_valid_ok, plasma_exact_valid_reason, plasma_exact_invalid_count] = ...
        expand_exact_valid_core_local(plasma_book, rs, nx, ny, nt);
    if plasma_active && dt_ok && drho_ofi_ok && plasma_exact_valid_ok
        if plasma_exact_invalid_count > 0
            partial_issues{end+1} = sprintf( ...
                'plasma_book.drho_ofi_applied:masked_invalid_exact_cells_unusable_%d', plasma_exact_invalid_count); %#ok<AGROW>
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'store_drho_ofi_xz', ...
                'exact_applied_ledger', 'masked_unusable', false);
        else
            ofi_rate_full = applied_increment_to_rate_local(drho_ofi_full, dt_row);
            step.store_drho_ofi_xz = squeeze(max(real(ofi_rate_full(:, iy_axis0, :)), [], 3));
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'store_drho_ofi_xz', ...
                'exact_applied_ledger', '', true);
        end
    elseif plasma_active && isstruct(plasma_book) && ~isempty(opt_restart_book_field_local(plasma_book, 'drho_ofi_applied')) && ...
            (~dt_ok || ~isempty(drho_ofi_reason) || ~plasma_exact_valid_ok)
        partial_issues{end+1} = sprintf('plasma_book.drho_ofi_applied:%s', ...
            join_issue_reasons_local(conditional_prefix_local(~dt_ok, dt_reason), ...
            drho_ofi_reason, plasma_exact_valid_core_reason, plasma_exact_valid_reason)); %#ok<AGROW>
    end
end
if plasma_active && dt_ok && drho_aval_core_ok && plasma_exact_valid_core_ok && ...
        isequal(drho_aval_core_idx, plasma_exact_valid_core_idx)
    plasma_exact_invalid_count = nnz(~plasma_exact_valid_core(:));
    if plasma_exact_invalid_count > 0
        partial_issues{end+1} = sprintf( ...
            'plasma_book.drho_aval_applied:masked_invalid_exact_cells_unusable_%d', plasma_exact_invalid_count); %#ok<AGROW>
        rebuild_meta = set_rebuild_provenance_local( ...
            rebuild_meta, 'store_drho_aval_xz', ...
            'exact_applied_ledger', 'masked_unusable', false);
    else
        aval_rate_core = applied_increment_to_rate_local(drho_aval_core, dt_row);
        [aval_axis_rows, aval_axis_ok, aval_axis_reason] = extract_core_td_axis_rows_local( ...
            aval_rate_core, drho_aval_core_idx, nx, ny, iy_axis0, 0);
        if aval_axis_ok
            step.store_drho_aval_xz = max(real(aval_axis_rows), [], 2);
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'store_drho_aval_xz', ...
                'exact_applied_ledger', '', true);
        elseif ~isempty(aval_axis_reason)
            partial_issues{end+1} = sprintf('plasma_book.drho_aval_applied:%s', aval_axis_reason); %#ok<AGROW>
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'store_drho_aval_xz', ...
                'exact_applied_ledger', aval_axis_reason, false);
        end
    end
else
    [drho_aval_full, drho_aval_ok, drho_aval_reason] = expand_core_or_full_td_local( ...
        opt_restart_book_field_local(plasma_book, 'drho_aval_applied'), rs, nx, ny, nt, 0);
    if ~exist('plasma_exact_valid_ok', 'var')
        [plasma_exact_valid_full, plasma_exact_valid_ok, plasma_exact_valid_reason, plasma_exact_invalid_count] = ...
            expand_exact_valid_core_local(plasma_book, rs, nx, ny, nt);
    end
    if plasma_active && dt_ok && drho_aval_ok && plasma_exact_valid_ok
        if plasma_exact_invalid_count > 0
            partial_issues{end+1} = sprintf( ...
                'plasma_book.drho_aval_applied:masked_invalid_exact_cells_unusable_%d', plasma_exact_invalid_count); %#ok<AGROW>
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'store_drho_aval_xz', ...
                'exact_applied_ledger', 'masked_unusable', false);
        else
            aval_rate_full = applied_increment_to_rate_local(drho_aval_full, dt_row);
            step.store_drho_aval_xz = squeeze(max(real(aval_rate_full(:, iy_axis0, :)), [], 3));
            rebuild_meta = set_rebuild_provenance_local( ...
                rebuild_meta, 'store_drho_aval_xz', ...
                'exact_applied_ledger', '', true);
        end
    elseif plasma_active && isstruct(plasma_book) && ~isempty(opt_restart_book_field_local(plasma_book, 'drho_aval_applied')) && ...
            (~dt_ok || ~isempty(drho_aval_reason) || ~plasma_exact_valid_ok)
        partial_issues{end+1} = sprintf('plasma_book.drho_aval_applied:%s', ...
            join_issue_reasons_local(conditional_prefix_local(~dt_ok, dt_reason), ...
            drho_aval_reason, plasma_exact_valid_core_reason, plasma_exact_valid_reason)); %#ok<AGROW>
    end
end
if plasma_active && isfield(rs, 'meta') && isstruct(rs.meta) && isfield(rs.meta, 'run_meta') && ...
        isstruct(rs.meta.run_meta) && isfield(rs.meta.run_meta, 'rho_nt_m3')
    rho_nt_local = double(real(rs.meta.run_meta.rho_nt_m3));
elseif plasma_active && isfield(rs.medium, 'rho_nt_m3')
    rho_nt_local = double(real(rs.medium.rho_nt_m3));
else
    rho_nt_local = NaN;
end
if plasma_active && isfinite(rho_nt_local) && (rho_nt_local > 0)
    if isfield(step, 'store_drho_ofi_xz') && any(isfinite(step.store_drho_ofi_xz(:)))
        ofi_val = max(step.store_drho_ofi_xz(:), [], 'omitnan');
        step.store_peak_drho_over_rho_nt_ofi = max(ofi_val, 0) / rho_nt_local;
    end
    if isfield(step, 'store_drho_aval_xz') && any(isfinite(step.store_drho_aval_xz(:)))
        aval_val = max(step.store_drho_aval_xz(:), [], 'omitnan');
        step.store_peak_drho_over_rho_nt_aval = max(aval_val, 0) / rho_nt_local;
    end
end
end

if rebuild_core
    phase_recenter_to_fund_t = [];
    if isfield(rs, 'grid') && isstruct(rs.grid)
        omega_window_phase = struct_utils.opt_struct_field(rs.grid, 'omega_window', []);
        omega_fund_phase = struct_utils.opt_struct_field(rs.grid, 'omega_fund', []);
        if ~isempty(omega_window_phase) && ~isempty(omega_fund_phase) && ...
                isfinite(double(real(omega_window_phase(1)))) && ...
                isfinite(double(real(omega_fund_phase)))
            omega_ref_phase = double(real(omega_window_phase(1)));
            omega_fund_phase = double(real(omega_fund_phase));
            phase_recenter_to_fund_t = exp(+1i * (omega_fund_phase - omega_ref_phase) * ...
                reshape(double(t), 1, 1, []));
        else
            partial_issues{end+1} = 'store_a_s_phase:missing_or_invalid_phase_recenter_metadata'; %#ok<AGROW>
        end
    else
        partial_issues{end+1} = 'store_a_s_phase:missing_phase_recenter_grid_metadata'; %#ok<AGROW>
    end
    % store_a_s_phase follows the shared omega_fund-centered envelope-phase
    % contract in storage_support.intensity_weighted_phase_mean(...),
    % including its relative low-intensity support floor. Do not fill this
    % physical-phase field from raw A_S when restart metadata cannot build
    % the recenter-to-fund factor.
    if isempty(phase_recenter_to_fund_t)
        step.store_a_s_phase = [];
    else
        step.store_a_s_phase = storage_support.intensity_weighted_phase_mean( ...
            A_S, intens_s, t, phase_recenter_to_fund_t);
    end
end
rebuild_meta.partial_issue_count = numel(partial_issues);
if ~isempty(partial_issues)
    rebuild_meta.partial_issue_reason = strjoin(partial_issues, ', ');
end
end

function aw_xyw = ensure_restart_spectral_field_local(aw_xyw, A_S)
% Lazily build the checkpoint spectral field only when a rebuild consumer needs it.
    if isempty(aw_xyw)
        aw_xyw = fft(A_S, [], 3);
    end
end

function af_mag2 = ensure_restart_spectral_power_local(af_mag2, aw_xyw)
% Lazily build the checkpoint spectral power cube only when a rebuild consumer needs it.
    if isempty(af_mag2)
        af_mag2 = real(aw_xyw .* conj(aw_xyw));
    end
end

function [af_mag2, weighted_a_ssf_mag2] = ensure_restart_weighted_spectral_density_local( ...
        af_mag2, weighted_a_ssf_mag2, aw_xyw, n_ratio_diag_xy, nx, ny)
% Build weighted raw mixed-space FFT power from A_SSF.
    if ~isempty(weighted_a_ssf_mag2)
        return;
    end
    af_mag2 = ensure_restart_spectral_power_local(af_mag2, aw_xyw);
    spectral_weight_xy = reshape(cast(n_ratio_diag_xy, 'like', af_mag2), nx, ny, 1);
    weighted_a_ssf_mag2 = af_mag2 .* spectral_weight_xy;
end

function [store_spectrum, status] = rebuild_store_spectrum_local( ...
        weighted_a_ssf_mag2, x, y, delta_t, delta_t_ok, delta_t_reason, ...
        diag_weight_ok, diag_weight_reason)
% Rebuild the driver-style area-integrated spectrum from the weighted mixed-space spectral density.
% Returns the rebuilt spectrum plus one compact status record with fields
% ok, source_tag, and reason. reason is non-exhaustive here: it may be a
% diag_weight_* failure, one of the joined t_/x_/y_ grid failures, or
% nonfinite_spectrum_reconstruction.
    store_spectrum = [];
    status = struct( ...
        'ok', false, ...
        'source_tag', '', ...
        'reason', 'missing_diag_weight');

    if ~(nargin >= 7 && logical(diag_weight_ok) && ~isempty(weighted_a_ssf_mag2))
        if nargin >= 8 && ischar(diag_weight_reason) && ~isempty(diag_weight_reason)
            status.reason = sprintf('diag_weight_%s', diag_weight_reason);
        end
        return;
    end

    [dx, dx_ok, dx_reason] = infer_grid_step_local(x, 'x');
    [dy, dy_ok, dy_reason] = infer_grid_step_local(y, 'y');
    if ~(dx_ok && dy_ok && delta_t_ok && isfinite(delta_t) && (delta_t > 0))
        status.reason = join_issue_reasons_local( ...
            conditional_prefix_local(~delta_t_ok, sprintf('t_%s', delta_t_reason)), ...
            conditional_prefix_local(~dx_ok, sprintf('x_%s', dx_reason)), ...
            conditional_prefix_local(~dy_ok, sprintf('y_%s', dy_reason)));
        return;
    end

    nt = size(weighted_a_ssf_mag2, 3);
    status.source_tag = 'sum_xy((n(x,y,omega_fund)/n_ref)*|FFT_t(A_S)|^2)*dx*dy*dt^2';

    s_omega = squeeze(dx * dy * sum(sum(weighted_a_ssf_mag2, 2), 1));
    s_omega_real = real(s_omega(:).');
    if numel(s_omega_real) ~= nt || any(~isfinite(s_omega_real))
        status.reason = 'nonfinite_spectrum_reconstruction';
        return;
    end
    store_spectrum = s_omega_real * (delta_t^2);
    status.ok = true;
    status.reason = '';
end

function diag = assign_step_local(diag, step, k, specs)
for ii = 1:numel(specs)
    diag = assign_diag_field_local(diag, step, k, specs(ii));
end
end

function [selected_step_record_idx, ordering_meta] = sort_selected_record_idx_local( ...
        selected_step_record_idx, file_records)
% Sort selected record indices before assignment so output slots are final.
% Uses lightweight checkpoint metadata only, so full rebuilt step payloads
% do not need to remain resident before the final assignment pass.
    ordering_meta = struct( ...
        'policy', '', ...
        'warning_key', '', ...
        'warning_id', '', ...
        'warning_message', '');
    if isempty(selected_step_record_idx)
        ordering_meta.policy = 'empty_selection';
        return;
    end
    n_selected = numel(selected_step_record_idx);
    z_key = NaN(n_selected, 1);
    step_key = NaN(n_selected, 1);
    datenum_key = NaN(n_selected, 1);
    for ii = 1:numel(selected_step_record_idx)
        record_idx = selected_step_record_idx(ii);
        if isfinite(record_idx) && isscalar(record_idx) && ...
                (record_idx >= 1) && (record_idx <= numel(file_records))
            if isfield(file_records(record_idx), 'selected_store_z') && ...
                    isfinite(file_records(record_idx).selected_store_z)
                z_key(ii) = double(file_records(record_idx).selected_store_z);
            end
            if is_valid_reassembly_store_step_idx_local(file_records(record_idx).store_step_idx)
                step_key(ii) = double(file_records(record_idx).store_step_idx);
            end
            if isfinite(file_records(record_idx).dir_datenum)
                datenum_key(ii) = double(file_records(record_idx).dir_datenum);
            end
        end
    end
    has_z = isfinite(z_key);
    has_step = isfinite(step_key);
    has_datenum = isfinite(datenum_key);
    fallback_order = (1:n_selected).';
    if all(has_z)
        sort_matrix = [z_key, fillmissing(datenum_key, 'constant', Inf), fallback_order];
        ordering_meta.policy = 'all_selected_store_z';
    elseif all(has_step)
        sort_matrix = [step_key, fillmissing(datenum_key, 'constant', Inf), fallback_order];
        ordering_meta.policy = 'all_store_step_idx';
    elseif all(has_datenum)
        sort_matrix = [datenum_key, fallback_order];
        ordering_meta.policy = 'all_dir_datenum';
    else
        error('CerUPP:RestartReassemblyMixedOrderingMetadata', ...
            ['Selected restart planes have mixed ordering metadata; reassembly now requires one usable ', ...
             'ordering key for every selected plane. Counts: selected_store_z=%d/%d, store_step_idx=%d/%d, ', ...
             'dir_datenum=%d/%d.'], ...
            nnz(has_z), n_selected, nnz(has_step), n_selected, nnz(has_datenum), n_selected);
    end
    [~, sort_idx] = sortrows(sort_matrix);
    selected_step_record_idx = selected_step_record_idx(sort_idx);
end

function file_records = init_reassembly_file_records_local(files, step_idx)
% Centralize checkpoint-level accounting into one internal record array.
    template = struct( ...
        'name', '', ...
        'store_step_idx', NaN, ...
        'dir_datenum', NaN, ...
        'restart_schema_detected', '', ...
        'restart_schema_version_detected', NaN, ...
        'restart_schema_status_code', 'unchecked', ...
        'restart_schema_status_detail', '', ...
        'reassembly_detail_status_code', 'unchecked', ...
        'reassembly_detail_status_detail', '', ...
        'validated', false, ...
        'validated_candidate_input', struct(), ...
        'validated_payload_cached', false, ...
        'validated_payload', struct(), ...
        'processed', false, ...
        'selected', false, ...
        'selected_output_slot', NaN, ...
        'selected_store_z', NaN, ...
        'rebuild_meta', struct());
    file_records = repmat(template, numel(files), 1);
    for ii = 1:numel(files)
        file_records(ii).name = files(ii).name;
        if nargin >= 2 && numel(step_idx) >= ii && ...
                is_valid_reassembly_store_step_idx_local(step_idx(ii))
            file_records(ii).store_step_idx = double(step_idx(ii));
        end
        if isfield(files, 'datenum') && isfinite(files(ii).datenum)
            file_records(ii).dir_datenum = double(files(ii).datenum);
        end
    end
end

function specs = reassembly_file_record_specs_local()
% Shared mapping from internal file-record fields to flat diag metadata arrays.
    specs = struct( ...
        'diag_field', {'source_checkpoint_files', 'store_step_idx', 'restart_schema_detected', ...
                       'restart_schema_version_detected', 'restart_schema_status', ...
                       'restart_schema_status_code', 'restart_schema_status_detail', ...
                       'reassembly_detail_status', 'reassembly_detail_status_code', ...
                       'reassembly_detail_status_detail'}, ...
        'record_field', {'name', 'store_step_idx', 'restart_schema_detected', ...
                         'restart_schema_version_detected', 'restart_schema_status', ...
                         'restart_schema_status_code', 'restart_schema_status_detail', ...
                         'reassembly_detail_status', 'reassembly_detail_status_code', ...
                         'reassembly_detail_status_detail'}, ...
        'value_kind', {'cellstr', 'double', 'cellstr', 'double', 'cellstr', 'cellstr', ...
                       'cellstr', 'cellstr', 'cellstr', 'cellstr'});
end

function diag = sync_reassembly_file_records_fieldset_local(diag, file_records, suffix)
% Derive the public flat per-checkpoint diag metadata from the internal record array.
    if nargin < 3
        suffix = '';
    end
    specs = reassembly_file_record_specs_local();
    for ii = 1:numel(specs)
        diag_field = [specs(ii).diag_field suffix];
        diag.(diag_field) = collect_reassembly_file_record_field_local( ...
            file_records, specs(ii).record_field, specs(ii).value_kind);
    end
end

function records_public = pack_reassembly_file_records_public_local(file_records)
% Pack one canonical per-checkpoint metadata inventory instead of parallel *_all arrays.
    template = struct( ...
        'source_checkpoint_file', '', ...
        'store_step_idx', NaN, ...
        'restart_schema_detected', '', ...
        'restart_schema_version_detected', NaN, ...
        'restart_schema_status', '', ...
        'restart_schema_status_code', '', ...
        'restart_schema_status_detail', '', ...
        'reassembly_detail_status', '', ...
        'reassembly_detail_status_code', '', ...
        'reassembly_detail_status_detail', '', ...
        'validated', false, ...
        'processed', false, ...
        'selected', false, ...
        'selected_output_slot', NaN);
    if isempty(file_records)
        records_public = repmat(template, 0, 1);
        return;
    end
    records_public = repmat(template, numel(file_records), 1);
    for ii = 1:numel(file_records)
        records_public(ii).source_checkpoint_file = file_records(ii).name;
        records_public(ii).store_step_idx = file_records(ii).store_step_idx;
        records_public(ii).restart_schema_detected = file_records(ii).restart_schema_detected;
        records_public(ii).restart_schema_version_detected = file_records(ii).restart_schema_version_detected;
        records_public(ii).restart_schema_status = assemble_reassembly_status_text_local( ...
            file_records(ii).restart_schema_status_code, ...
            file_records(ii).restart_schema_status_detail);
        records_public(ii).restart_schema_status_code = file_records(ii).restart_schema_status_code;
        records_public(ii).restart_schema_status_detail = file_records(ii).restart_schema_status_detail;
        records_public(ii).reassembly_detail_status = assemble_reassembly_status_text_local( ...
            file_records(ii).reassembly_detail_status_code, ...
            file_records(ii).reassembly_detail_status_detail);
        records_public(ii).reassembly_detail_status_code = file_records(ii).reassembly_detail_status_code;
        records_public(ii).reassembly_detail_status_detail = file_records(ii).reassembly_detail_status_detail;
        records_public(ii).validated = logical(file_records(ii).validated);
        records_public(ii).processed = logical(file_records(ii).processed);
        records_public(ii).selected = logical(file_records(ii).selected);
        records_public(ii).selected_output_slot = file_records(ii).selected_output_slot;
    end
end

function values = collect_reassembly_file_record_field_local(file_records, record_field, value_kind)
% Collect one typed column vector/cell array from the internal file-record array.
    if nargin < 3 || isempty(value_kind)
        value_kind = 'cellstr';
    end
    if isempty(file_records)
        switch value_kind
            case 'cellstr'
                values = cell(0, 1);
            case 'double'
                values = NaN(0, 1);
            case 'logical'
                values = false(0, 1);
            otherwise
                error('assemble_diagnostics_from_restart:UnknownRecordValueKind', ...
                    'Unknown reassembly file-record value kind "%s".', value_kind);
        end
        return;
    end
    if strcmp(value_kind, 'cellstr') && strcmp(record_field, 'restart_schema_status')
        values = cell(numel(file_records), 1);
        for ii = 1:numel(file_records)
            values{ii} = assemble_reassembly_status_text_local( ...
                file_records(ii).restart_schema_status_code, ...
                file_records(ii).restart_schema_status_detail);
        end
        return;
    end
    if strcmp(value_kind, 'cellstr') && strcmp(record_field, 'reassembly_detail_status')
        values = cell(numel(file_records), 1);
        for ii = 1:numel(file_records)
            values{ii} = assemble_reassembly_status_text_local( ...
                file_records(ii).reassembly_detail_status_code, ...
                file_records(ii).reassembly_detail_status_detail);
        end
        return;
    end
    switch value_kind
        case 'cellstr'
            values = reshape({file_records.(record_field)}, [], 1);
        case 'double'
            values = reshape([file_records.(record_field)], [], 1);
        case 'logical'
            values = reshape(logical([file_records.(record_field)]), [], 1);
        otherwise
            error('assemble_diagnostics_from_restart:UnknownRecordValueKind', ...
                'Unknown reassembly file-record value kind "%s".', value_kind);
    end
end

function diag = sync_reassembly_selection_summary_local(diag, file_records, latest_only_mode)
% Derive mask/skipped summaries from the internal file-record array.
    processed_mask = collect_reassembly_file_record_field_local(file_records, 'processed', 'logical');
    selected_mask = collect_reassembly_file_record_field_local(file_records, 'selected', 'logical');
    validated_mask = collect_reassembly_file_record_field_local(file_records, 'validated', 'logical');
    diag.processed_mask = processed_mask;
    diag.selected_mask = selected_mask;
    skipped_records = file_records(~selected_mask);
    diag.skipped_checkpoint_files = collect_reassembly_file_record_field_local(skipped_records, 'name', 'cellstr');
    diag.skipped_checkpoint_status = collect_reassembly_file_record_field_local(skipped_records, 'restart_schema_status', 'cellstr');
    diag.skipped_checkpoint_status_code = collect_reassembly_file_record_field_local(skipped_records, 'restart_schema_status_code', 'cellstr');
    diag.skipped_checkpoint_status_detail = collect_reassembly_file_record_field_local(skipped_records, 'restart_schema_status_detail', 'cellstr');
    skipped_reason_full = collect_reassembly_file_record_field_local(file_records, 'reassembly_detail_status', 'cellstr');
    skipped_reason_code_full = collect_reassembly_file_record_field_local(file_records, 'reassembly_detail_status_code', 'cellstr');
    skipped_reason_detail_full = collect_reassembly_file_record_field_local(file_records, 'reassembly_detail_status_detail', 'cellstr');
    if latest_only_mode
        skipped_reason_full(validated_mask & ~selected_mask) = {'not_selected_latest_only'};
        skipped_reason_code_full(validated_mask & ~selected_mask) = {'not_selected_latest_only'};
        skipped_reason_detail_full(validated_mask & ~selected_mask) = {''};
    end
    diag.skipped_checkpoint_reason = skipped_reason_full(~selected_mask);
    diag.skipped_checkpoint_reason_code = skipped_reason_code_full(~selected_mask);
    diag.skipped_checkpoint_reason_detail = skipped_reason_detail_full(~selected_mask);
end

function file_records = set_reassembly_record_status_local(file_records, record_idx, status_prefix, status_code, status_detail)
% Keep status code/detail as the internal source of truth.
    if nargin < 5 || isempty(status_detail)
        status_detail = '';
    end
    status_code = char(string(status_code));
    status_detail = char(string(status_detail));
    file_records(record_idx).([status_prefix '_status_code']) = status_code;
    file_records(record_idx).([status_prefix '_status_detail']) = status_detail;
end

function [file_records, reassembly_warn_state] = reject_checkpoint_candidate_local( ...
        file_records, record_idx, checkpoint_name, status_prefix, status_code, ...
        status_detail, reassembly_warn_state, reassembly_warn_phase, ...
        warning_id, warning_message, varargin)
% Apply one shared reject-and-warn path for a checkpoint candidate.

    file_records = set_reassembly_record_status_local( ...
        file_records, record_idx, status_prefix, status_code, status_detail);
    reassembly_warn_state = run_warn_state_utils.emit_softwarn_each_time_with_phase( ...
        reassembly_warn_state, reassembly_warn_phase, warning_id, ...
        warning_message, checkpoint_name, varargin{:});
end

function setup_ctx = build_reassembly_setup_ctx_local( ...
    run_dir, make_plots, outdir, latest_only, ...
    prefer_latest_pointer, verify_saved_payload, rebuild_policy)
% Assemble one compact setup context for reassembly policy, I/O, and warnings.
    selection_policy = struct( ...
        'latest_only', logical(latest_only), ...
        'prefer_latest_pointer', logical(prefer_latest_pointer));
    if selection_policy.latest_only
        diag_output_name = 'diagnostics_from_restart_latest.mat';
        diag_scope = 'latest_only';
    else
        diag_output_name = 'diagnostics_from_restart_all.mat';
        diag_scope = 'all_checkpoints';
    end
    if make_plots
        if isempty(outdir)
            outdir = fullfile(run_dir, 'output_plots_reassembled');
        end
    else
        outdir = '';
    end
    check_dir = fullfile(run_dir, 'checkpoints');
    if ~exist(check_dir, 'dir')
        error('CerUPP:MissingCheckpointDir', ...
            ['Checkpoint directory not found: %s. ', ...
             'run_dir must be a saved run directory containing checkpoints/.'], ...
            check_dir);
    end
    setup_ctx = struct( ...
        'selection_policy', selection_policy, ...
        'rebuild_policy', rebuild_policy, ...
        'diag_output_name', diag_output_name, ...
        'diag_scope', diag_scope, ...
        'io_ctx', struct( ...
            'run_dir', run_dir, ...
            'check_dir', check_dir, ...
            'outdir', outdir, ...
            'diag_output_file', fullfile(run_dir, diag_output_name), ...
            'verify_saved_payload_flag', logical(verify_saved_payload)), ...
        'warning_owner', 'reassembly', ...
        'warning_phase', run_warn_state_utils.phase_end(), ...
        'warning_state', struct());
end

function candidate_input = build_validated_reassembly_candidate_input_local( ...
        nx, ny, nt, diag_weight_ok, diag_weight_reason, diag_weight_note)
% Capture the lightweight validated metadata produced during the validation pass.
    candidate_input = struct( ...
        'grid_shape', [nx, ny, nt], ...
        'diag_weight_ok', diag_weight_ok, ...
        'diag_weight_reason', diag_weight_reason, ...
        'diag_weight_note', diag_weight_note);
end

function rebuild_policy = normalize_reassembly_rebuild_policy_local(families_raw, option_was_default)
% Normalize rebuild_families into explicit family booleans.
% Explicit requests are strict-selective; only the common plane-index
% fields remain mandatory outside the requested family set.
    if nargin < 2 || isempty(option_was_default)
        option_was_default = false;
    end
    requested_families = normalize_reassembly_requested_families_local(families_raw);
    requested_families = unique(requested_families(:), 'stable').';
    allowed_families = {'core', 'bands_rgb', 'full_spectrum', 'plasma_nla'};
    invalid_families = requested_families(~ismember(requested_families, allowed_families));
    if ~isempty(invalid_families)
        error('assemble_diagnostics_from_restart:InvalidRebuildFamilies', ...
            'Unknown rebuild family/families: %s', strjoin(invalid_families, ', '));
    end
    mode_name = 'strict_selective';
    if logical(option_was_default)
        mode_name = 'default_full';
    end
    rebuild_policy = struct( ...
        'mode', mode_name, ...
        'option_was_default', logical(option_was_default), ...
        'requested_families', {requested_families}, ...
        'core', ismember('core', requested_families), ...
        'bands_rgb', ismember('bands_rgb', requested_families), ...
        'full_spectrum', ismember('full_spectrum', requested_families), ...
        'plasma_nla', ismember('plasma_nla', requested_families), ...
        'explicit_bands_rgb_request', ~logical(option_was_default) && ismember('bands_rgb', requested_families), ...
        'explicit_full_spectrum_request', ~logical(option_was_default) && ismember('full_spectrum', requested_families), ...
        'explicit_plasma_nla_request', ~logical(option_was_default) && ismember('plasma_nla', requested_families));
end

function requested_families = normalize_reassembly_requested_families_local(families_raw)
% Normalize requested rebuild-family tokens onto the canonical family names.
    if isstring(families_raw) && isscalar(families_raw)
        families_raw = char(families_raw);
    end
    if ischar(families_raw)
        requested_families = {families_raw};
    elseif isstring(families_raw)
        requested_families = cellstr(families_raw(:));
    elseif iscell(families_raw)
        requested_families = families_raw(:);
    else
        error('assemble_diagnostics_from_restart:InvalidRebuildFamiliesType', ...
            'rebuild_families must be a char, string, or cell array.');
    end
    for ii = 1:numel(requested_families)
        token = requested_families{ii};
        if isstring(token) && isscalar(token)
            token = char(token);
        end
        if ~(ischar(token) && isrow(token))
            error('assemble_diagnostics_from_restart:InvalidRebuildFamilyEntry', ...
                'Each rebuild_families entry must be a char row or scalar string.');
        end
        token = lower(strtrim(token));
        if isempty(token)
            error('assemble_diagnostics_from_restart:InvalidRebuildFamilyEntry', ...
                'rebuild_families entries must be nonblank.');
        end
        requested_families{ii} = token;
    end
end

function [diag, file_records] = publish_reassembly_file_record_views_local( ...
        diag, file_records, selected_step_record_idx, selection_policy, stores_allocated)
% Publish the canonical file-record inventory into the public output views.
    if nargin < 5
        stores_allocated = true;
    end
    if nargin < 4 || isempty(selection_policy) || ~isstruct(selection_policy)
        selection_policy = struct('latest_only', false, 'prefer_latest_pointer', false);
    end
    if ~stores_allocated
        selected_records = file_records;
    elseif selection_policy.latest_only
        selected_records = file_records(collect_reassembly_file_record_field_local( ...
            file_records, 'selected', 'logical'));
    else
        selected_records = file_records(selected_step_record_idx);
    end
    file_records = assign_reassembly_selected_output_slots_local( ...
        file_records, selected_records, stores_allocated);
    diag = sync_reassembly_file_records_fieldset_local(diag, selected_records, '');
    diag.reassembly_file_records = pack_reassembly_file_records_public_local(file_records);
end

function file_records = assign_reassembly_selected_output_slots_local( ...
        file_records, selected_records, stores_allocated)
% Derive the public selected_output_slot view from the canonical file-record array.
    if nargin < 3 || ~stores_allocated || isempty(file_records)
        return;
    end
    for ii = 1:numel(file_records)
        if file_records(ii).selected
            file_records(ii).selected_output_slot = NaN;
        end
    end
    selected_names = collect_reassembly_file_record_field_local(selected_records, 'name', 'cellstr');
    for out_idx = 1:numel(selected_names)
        match_idx = find(strcmp({file_records.name}, selected_names{out_idx}), 1, 'first');
        if ~isempty(match_idx)
            file_records(match_idx).selected_output_slot = out_idx;
        end
    end
end

function [rs, sidecar_cache] = require_restart_payload_groups_local(rs, check_dir, checkpoint_name, sidecar_cache)
% Require the current structured restart payload shape and resolve companion-file-backed common groups.
    if nargin < 4 || isempty(sidecar_cache)
        sidecar_cache = init_restart_sidecar_cache_local();
    end
    if nargin < 1 || ~(isstruct(rs) && isscalar(rs))
        error('CerUPP:RestartPayloadInvalid', ...
            'restart_state must be a scalar struct.');
    end
    required_groups = struct_utils.restart_required_groups();
    missing_groups = required_groups(~isfield(rs, required_groups));
    if ~isempty(missing_groups)
        error('CerUPP:RestartPayloadMissingGroups', ...
            ['Restart payload must contain the structured groups %s. ', ...
             'Missing: %s'], ...
            strjoin(required_groups, '/'), strjoin(missing_groups, ', '));
    end
    for ii = 1:numel(required_groups)
        group_name = required_groups{ii};
        if ~(isstruct(rs.(group_name)) && isscalar(rs.(group_name)))
            error('CerUPP:RestartPayloadBadGroup', ...
                'Restart payload group "%s" must be a scalar struct.', group_name);
        end
    end
    common_group_names = {'grid', 'medium', 'ops'};
    sidecar_file = '';
    needs_sidecar = false;
    sidecar_ref_mask = false(1, numel(common_group_names));
    for ii = 1:numel(common_group_names)
        group_name = common_group_names{ii};
        group_struct = rs.(group_name);
        if is_restart_common_group_sidecar_ref_local(group_struct)
            needs_sidecar = true;
            sidecar_ref_mask(ii) = true;
            group_sidecar_file = char(string(group_struct.sidecar_file));
            if isempty(sidecar_file)
                sidecar_file = group_sidecar_file;
            elseif ~strcmp(sidecar_file, group_sidecar_file)
                error('CerUPP:RestartPayloadMixedCommonSidecars', ...
                    ['Restart payload common groups reference multiple companion files ', ...
                     '(%s vs %s).'], sidecar_file, group_sidecar_file);
            end
        end
    end
    if needs_sidecar && ~all(sidecar_ref_mask)
        embedded_groups = common_group_names(~sidecar_ref_mask);
        sidecar_groups = common_group_names(sidecar_ref_mask);
        error('CerUPP:RestartPayloadMixedEmbeddedAndSidecarCommonGroups', ...
            ['Restart payload common groups grid/medium/ops must be all embedded or all ', ...
             'stored in companion MAT files. Found embedded group(s) %s and companion-file group(s) %s.'], ...
            strjoin(embedded_groups, ', '), strjoin(sidecar_groups, ', '));
    end
    if needs_sidecar
        if nargin < 2 || isempty(check_dir)
            error('CerUPP:RestartPayloadMissingSidecarContext', ...
                'check_dir is required to resolve companion-file-backed restart common groups.');
        end
        if nargin < 3 || isempty(checkpoint_name)
            checkpoint_name = '(unknown checkpoint)';
        end
        [common_groups, sidecar_cache] = load_restart_common_groups_sidecar_local( ...
            check_dir, sidecar_file, checkpoint_name, sidecar_cache);
        for ii = 1:numel(common_group_names)
            group_name = common_group_names{ii};
            if is_restart_common_group_sidecar_ref_local(rs.(group_name))
                rs.(group_name) = common_groups.(group_name);
            end
        end
    end
    if ~isfield(rs, 'meta') || isempty(rs.meta)
        rs.meta = struct();
    elseif ~(isstruct(rs.meta) && isscalar(rs.meta))
        error('CerUPP:RestartPayloadBadMeta', ...
            'Restart payload field "meta" must be a scalar struct when present.');
    end
    [rs, sidecar_cache] = maybe_merge_restart_diag_reassembly_state_local( ...
        rs, check_dir, checkpoint_name, sidecar_cache);
end

function tf = is_restart_common_group_sidecar_ref_local(group_struct)
    tf = is_restart_sidecar_ref_local(group_struct, 'checkpoint_common_groups_sidecar_ref');
end

function tf = is_restart_sidecar_ref_local(ref_struct, storage_owner)
% Canonical companion-file reference detector shared by restart payload loaders.
    if nargin < 2 || isempty(storage_owner)
        storage_owner = '';
    end
    tf = isstruct(ref_struct) && isscalar(ref_struct) && ...
        isfield(ref_struct, 'storage_owner') && ...
        isfield(ref_struct, 'sidecar_file') && ...
        strcmp(char(string(ref_struct.storage_owner)), char(string(storage_owner)));
end

function [common_groups, sidecar_cache] = load_restart_common_groups_sidecar_local( ...
    check_dir, sidecar_file, checkpoint_name, sidecar_cache)
    if nargin < 4 || isempty(sidecar_cache)
        sidecar_cache = init_restart_sidecar_cache_local();
    end
    if nargin < 2 || isempty(sidecar_file)
        error('CerUPP:RestartPayloadMissingCommonSidecarFile', ...
            'Restart checkpoint %s is missing the common-group companion file reference.', checkpoint_name);
    end
    sidecar_path = fullfile(check_dir, sidecar_file);
    if exist(sidecar_path, 'file') ~= 2
        error('CerUPP:RestartPayloadCommonSidecarMissing', ...
            'Restart checkpoint %s references missing common-group companion file %s.', ...
            checkpoint_name, sidecar_path);
    end
    if isKey(sidecar_cache.common_groups_by_path, sidecar_path)
        common_groups = sidecar_cache.common_groups_by_path(sidecar_path);
        return;
    end
    sidecar_data = load(sidecar_path, 'restart_common_groups');
    if ~isfield(sidecar_data, 'restart_common_groups') || ...
            ~(isstruct(sidecar_data.restart_common_groups) && isscalar(sidecar_data.restart_common_groups))
        error('CerUPP:RestartPayloadCommonSidecarInvalid', ...
            ['Restart checkpoint %s references common-group companion file %s, but ', ...
             'that file does not contain a valid scalar restart_common_groups struct.'], ...
            checkpoint_name, sidecar_path);
    end
    common_groups = sidecar_data.restart_common_groups;
    required_common_groups = {'grid', 'medium', 'ops'};
    missing_groups = required_common_groups(~isfield(common_groups, required_common_groups));
    if ~isempty(missing_groups)
        error('CerUPP:RestartPayloadCommonSidecarMissingGroups', ...
            ['Restart checkpoint %s references common-group companion file %s missing group(s): %s.'], ...
            checkpoint_name, sidecar_path, strjoin(missing_groups, ', '));
    end
    for ii = 1:numel(required_common_groups)
        group_name = required_common_groups{ii};
        if ~(isstruct(common_groups.(group_name)) && isscalar(common_groups.(group_name)))
            error('CerUPP:RestartPayloadCommonSidecarBadGroup', ...
            ['Restart checkpoint %s references common-group companion file %s with ', ...
                 'non-scalar-struct group "%s".'], checkpoint_name, sidecar_path, group_name);
        end
    end
    sidecar_cache.common_groups_by_path(sidecar_path) = common_groups;
end

function tf = is_valid_reassembly_store_step_idx_local(step_idx)
% Accept only positive integer-valued scalar step indices for ordering metadata.
    tf = isnumeric(step_idx) && isreal(step_idx) && isscalar(step_idx) && ...
        isfinite(step_idx) && (double(step_idx) > 0) && ...
        (round(double(step_idx)) == double(step_idx));
end

function [rs, sidecar_cache] = maybe_merge_restart_diag_reassembly_state_local( ...
    rs, check_dir, checkpoint_name, sidecar_cache)
% Merge optional diagnostic-reassembly-only companion state into rs.state.
    if nargin < 4 || isempty(sidecar_cache)
        sidecar_cache = init_restart_sidecar_cache_local();
    end
    sidecar_ref = resolve_restart_diag_reassembly_ref_local(rs.meta);
    storage_mode = char(string(struct_utils.opt_struct_field(sidecar_ref, 'storage_owner', '')));
    if isempty(storage_mode) || strcmp(storage_mode, 'embedded_in_restart_state')
        return;
    end
    if ~strcmp(storage_mode, 'checkpoint_diag_reassembly_sidecar_ref')
        error('CerUPP:RestartPayloadDiagReassemblyStorageInvalid', ...
            'Restart checkpoint %s has unknown diag_reassembly_state_ref.storage_owner=%s.', ...
            checkpoint_name, storage_mode);
    end
    if nargin < 2 || isempty(check_dir)
        error('CerUPP:RestartPayloadMissingDiagReassemblyContext', ...
            'check_dir is required to resolve restart diagnostic reassembly companion files.');
    end
    sidecar_file = char(string(struct_utils.opt_struct_field(sidecar_ref, 'sidecar_file', '')));
    if isempty(sidecar_file)
        error('CerUPP:RestartPayloadMissingDiagReassemblySidecarFile', ...
            'Restart checkpoint %s is missing the companion-file name field in diag_reassembly_state_ref.', ...
            checkpoint_name);
    end
    payload_tag = char(string(struct_utils.opt_struct_field( ...
        sidecar_ref, 'payload_tag', 'restart_diag_reassembly_state')));
    if ~strcmp(payload_tag, 'restart_diag_reassembly_state')
        error('CerUPP:RestartPayloadDiagReassemblyPayloadTagInvalid', ...
            ['Restart checkpoint %s has diag_reassembly_state_ref.payload_tag=%s. ', ...
             'Expected restart_diag_reassembly_state.'], ...
            checkpoint_name, payload_tag);
    end
    sidecar_path = fullfile(check_dir, sidecar_file);
    if exist(sidecar_path, 'file') ~= 2
        error('CerUPP:RestartPayloadDiagReassemblySidecarMissing', ...
            'Restart checkpoint %s references missing diag reassembly companion file %s.', ...
            checkpoint_name, sidecar_path);
    end
    if isKey(sidecar_cache.diag_reassembly_by_path, sidecar_path)
        diag_reassembly_state = sidecar_cache.diag_reassembly_by_path(sidecar_path);
    else
        sidecar_data = load(sidecar_path, 'restart_diag_reassembly_state');
        if ~isfield(sidecar_data, 'restart_diag_reassembly_state') || ...
                ~(isstruct(sidecar_data.restart_diag_reassembly_state) && ...
                  isscalar(sidecar_data.restart_diag_reassembly_state))
            error('CerUPP:RestartPayloadDiagReassemblySidecarInvalid', ...
                ['Restart checkpoint %s references diag reassembly companion file %s, but ', ...
                 'that file does not contain a valid scalar restart_diag_reassembly_state struct.'], ...
                checkpoint_name, sidecar_path);
        end
        diag_reassembly_state = sidecar_data.restart_diag_reassembly_state;
        sidecar_cache.diag_reassembly_by_path(sidecar_path) = diag_reassembly_state;
    end
    checkpoint_utils.reject_restart_diag_reassembly_state_field_collisions( ...
        rs.state, diag_reassembly_state, checkpoint_name);
    field_names = fieldnames(diag_reassembly_state);
    for ii = 1:numel(field_names)
        field_name = field_names{ii};
        rs.state.(field_name) = diag_reassembly_state.(field_name);
    end
end

function sidecar_ref = resolve_restart_diag_reassembly_ref_local(meta_struct)
% Resolve the canonical diag-reassembly ref record from restart metadata.
    sidecar_ref = struct( ...
        'storage_owner', '', ...
        'sidecar_file', '', ...
        'payload_tag', 'restart_diag_reassembly_state');
    if ~(isstruct(meta_struct) && isscalar(meta_struct))
        return;
    end
    if isfield(meta_struct, 'diag_reassembly_state_ref') && ...
            isstruct(meta_struct.diag_reassembly_state_ref) && ...
            isscalar(meta_struct.diag_reassembly_state_ref)
        sidecar_ref.storage_owner = char(string(struct_utils.opt_struct_field( ...
            meta_struct.diag_reassembly_state_ref, 'storage_owner', '')));
        sidecar_ref.sidecar_file = char(string(struct_utils.opt_struct_field( ...
            meta_struct.diag_reassembly_state_ref, 'sidecar_file', '')));
        sidecar_ref.payload_tag = char(string(struct_utils.opt_struct_field( ...
            meta_struct.diag_reassembly_state_ref, 'payload_tag', ...
            'restart_diag_reassembly_state')));
    end
end

function sidecar_cache = init_restart_sidecar_cache_local()
% Invocation-local cache for repeated companion-file-backed restart payload groups.
    sidecar_cache = struct( ...
        'common_groups_by_path', containers.Map('KeyType', 'char', 'ValueType', 'any'), ...
        'diag_reassembly_by_path', containers.Map('KeyType', 'char', 'ValueType', 'any'));
end

function shape_descriptor = diag_shape_descriptor_local(spec)
% Resolve the explicit long-form checkpoint diag shape for one schema row.
    shape_descriptor = '';
    if isstruct(spec)
        shape_descriptor = char(string(struct_utils.opt_struct_field(spec, 'shape_descriptor', '')));
    end
    shape_descriptor = strtrim(shape_descriptor);
    if isempty(shape_descriptor)
        shape_descriptor = checkpoint_utils.diag_shape_descriptor_from_family( ...
            struct_utils.req_struct_field(spec, 'family', 'diag schema spec'));
    end
end

function arr = allocate_diag_store_field_local(spec, nsave, nx, ny, nt)
% Allocate one reconstructed diagnostic store by explicit shape descriptor.
    shape_descriptor = diag_shape_descriptor_local(spec);
    switch shape_descriptor
        case 'time_history_2d'
            arr = make_nan_array_local([nsave, nt], spec.is_complex);
        case 'xy_map_stack_3d'
            arr = make_nan_array_local([nx, ny, nsave], spec.is_complex);
        case 'xy_spectral_cube_4d'
            arr = make_nan_array_local([nx, ny, nt, nsave], spec.is_complex);
        case 'xz_trace_2d'
            arr = make_nan_array_local([nx, nsave], spec.is_complex);
        case 'row_vector'
            arr = make_nan_array_local([1, nsave], spec.is_complex);
        case 'column_vector'
            arr = make_nan_array_local([nsave, 1], spec.is_complex);
        case 'core_time_history_3d'
            arr = [];
        otherwise
            error('assemble_diagnostics_from_restart:UnknownDiagFieldFamily', ...
                'Unknown diagnostic field shape "%s" for %s.', shape_descriptor, spec.name);
    end
end


function diag = ensure_diag_store_field_local(diag, spec)
% Allocate one diagnostic field lazily the first time restart assembly writes it.
    field_name = spec.name;
    if isfield(diag, field_name) && ~isempty(diag.(field_name))
        return;
    end
    if ~isfield(diag, 'reassembly_store_alloc_ctx') || ~isstruct(diag.reassembly_store_alloc_ctx)
        error('assemble_diagnostics_from_restart:MissingStoreAllocCtx', ...
            'Restart diagnostic store allocation context is missing while allocating %s.', field_name);
    end
    ctx = diag.reassembly_store_alloc_ctx;
    diag.(field_name) = allocate_diag_store_field_local( ...
        spec, ctx.nsave, ctx.nx, ctx.ny, ctx.nt);
end

function diag = finalize_diag_store_fields_local(diag)
% Preserve the external diag-field contract without preallocating untouched arrays.
    specs = checkpoint_utils.diag_field_specs();
    for ii = 1:numel(specs)
        field_name = specs(ii).name;
        if ~isfield(diag, field_name)
            diag.(field_name) = [];
        end
    end
end

function diag = clear_diag_store_alloc_ctx_local(diag)
% Remove the internal lazy-allocation context before saving the public diag struct.
    if isfield(diag, 'reassembly_store_alloc_ctx')
        diag = rmfield(diag, 'reassembly_store_alloc_ctx');
    end
end

function tf = has_reassembly_grid_ref_ctx_local(diag)
% Report whether the hidden physical-grid reference context has been set.
    tf = isstruct(diag) && isfield(diag, 'reassembly_grid_ref_ctx') && ...
        isstruct(diag.reassembly_grid_ref_ctx) && ...
        isfield(diag.reassembly_grid_ref_ctx, 'x') && ...
        isfield(diag.reassembly_grid_ref_ctx, 'y') && ...
        isfield(diag.reassembly_grid_ref_ctx, 't') && ...
        isfield(diag.reassembly_grid_ref_ctx, 'checkpoint_name') && ...
        ~isempty(diag.reassembly_grid_ref_ctx.x) && ...
        ~isempty(diag.reassembly_grid_ref_ctx.y) && ...
        ~isempty(diag.reassembly_grid_ref_ctx.t);
end

function diag = set_reassembly_grid_ref_ctx_local(diag, x, y, t, checkpoint_name)
% Pin the first accepted checkpoint's physical grid vectors as the reassembly reference.
    diag.reassembly_grid_ref_ctx = struct( ...
        'x', double(x(:)), ...
        'y', double(y(:)), ...
        't', double(t(:)), ...
        'checkpoint_name', char(string(checkpoint_name)));
end

function [match_ok, mismatch_detail, mismatch_msg] = compare_reassembly_grid_vectors_local(ref_ctx, x, y, t)
% Compare one checkpoint's physical grid vectors against the established reassembly reference.
    match_ok = true;
    mismatch_detail = '';
    mismatch_msg = '';
    axis_specs = { ...
        'x', ref_ctx.x, x(:); ...
        'y', ref_ctx.y, y(:); ...
        't', ref_ctx.t, t(:)};
    for ii = 1:size(axis_specs, 1)
        axis_name = axis_specs{ii, 1};
        [axis_ok, max_abs_delta, tol, axis_detail] = compare_reassembly_grid_vector_local( ...
            axis_specs{ii, 2}, axis_specs{ii, 3});
        if axis_ok
            continue;
        end
        match_ok = false;
        mismatch_detail = sprintf('%s:%s', axis_name, axis_detail);
        mismatch_msg = sprintf('%s-axis mismatch: %s (max|delta|=%.6e, tol=%.6e)', ...
            axis_name, axis_detail, max_abs_delta, tol);
        return;
    end
end

function [rs, x, y, t, n_ratio_diag_xy] = load_validated_reassembly_checkpoint_payload_local( ...
        checkpoint_dir, checkpoint_name)
% Reload one selected checkpoint payload on demand during rebuild.
    try
        s = load(fullfile(checkpoint_dir, checkpoint_name), 'restart_state');
    catch me_load
        error('assemble_diagnostics_from_restart:SelectedCheckpointReloadFailed', ...
            'Failed to reload selected checkpoint %s during rebuild: %s', ...
            checkpoint_name, me_load.message);
    end
    if ~isfield(s, 'restart_state') || isempty(s.restart_state)
        error('assemble_diagnostics_from_restart:MissingRestartStateOnReload', ...
            'Selected checkpoint %s no longer contains restart_state during rebuild.', ...
            checkpoint_name);
    end
    [rs, ~] = require_restart_payload_groups_local( ...
        s.restart_state, checkpoint_dir, checkpoint_name, init_restart_sidecar_cache_local());
    if ~isfield(rs, 'grid') || ~isstruct(rs.grid) || ...
            ~isfield(rs.grid, 'x') || isempty(rs.grid.x) || ...
            ~isfield(rs.grid, 'y') || isempty(rs.grid.y) || ...
            ~isfield(rs.grid, 't') || isempty(rs.grid.t)
        error('assemble_diagnostics_from_restart:SelectedCheckpointGridMissingOnReload', ...
            'Selected checkpoint %s is missing x/y/t grid vectors during rebuild.', ...
            checkpoint_name);
    end
    x = rs.grid.x(:);
    y = rs.grid.y(:);
    t = rs.grid.t(:).';
    A_S = struct_utils.req_struct_field( ...
        rs.state, 'A_S', 'load_validated_reassembly_checkpoint_payload_local rs.state');
    [nx, ny, nt] = size(A_S);
    if numel(x) ~= nx || numel(y) ~= ny || numel(t) ~= nt
        error('assemble_diagnostics_from_restart:SelectedCheckpointGridMismatchOnReload', ...
            'Selected checkpoint %s changed grid shape between validation and rebuild.', ...
            checkpoint_name);
    end
    [n_ratio_diag_xy, ~, ~, ~] = build_restart_diag_weight_map_local( ...
        rs, nx, ny, nt, real(A_S(1)));
end

function [rs, x, y, t, n_ratio_diag_xy] = reuse_or_load_validated_reassembly_checkpoint_payload_local( ...
        file_record, checkpoint_dir, checkpoint_name)
% Reuse one bounded cached payload when the validation pass kept it in memory.
    if isstruct(file_record) && logical(struct_utils.opt_struct_field( ...
            file_record, 'validated_payload_cached', false))
        cached_payload = struct_utils.opt_struct_field(file_record, 'validated_payload', struct());
        if isstruct(cached_payload) && ...
                isfield(cached_payload, 'rs') && isfield(cached_payload, 'x') && ...
                isfield(cached_payload, 'y') && isfield(cached_payload, 't') && ...
                isfield(cached_payload, 'n_ratio_diag_xy')
            rs = cached_payload.rs;
            x = cached_payload.x;
            y = cached_payload.y;
            t = cached_payload.t;
            n_ratio_diag_xy = cached_payload.n_ratio_diag_xy;
            return;
        end
    end
    [rs, x, y, t, n_ratio_diag_xy] = load_validated_reassembly_checkpoint_payload_local( ...
        checkpoint_dir, checkpoint_name);
end

function [file_record, payload_cache_bytes] = maybe_cache_validated_reassembly_payload_local( ...
        file_record, rs, x, y, t, n_ratio_diag_xy, A_S, payload_cache_bytes, payload_cache_budget_bytes)
% Keep a bounded in-memory cache of selected restart payloads to avoid reloading small sets.
    if nargin < 9 || ~isscalar(payload_cache_budget_bytes) || ...
            ~isfinite(payload_cache_budget_bytes) || (payload_cache_budget_bytes <= 0)
        return;
    end
    estimated_payload_bytes = estimate_reassembly_payload_bytes_local(A_S, x, y, t, n_ratio_diag_xy);
    if ~isfinite(estimated_payload_bytes) || (estimated_payload_bytes <= 0) || ...
            ((payload_cache_bytes + estimated_payload_bytes) > payload_cache_budget_bytes)
        return;
    end
    file_record.validated_payload_cached = true;
    file_record.validated_payload = struct( ...
        'rs', rs, ...
        'x', x, ...
        'y', y, ...
        't', t, ...
        'n_ratio_diag_xy', n_ratio_diag_xy);
    payload_cache_bytes = payload_cache_bytes + estimated_payload_bytes;
end

function estimated_payload_bytes = estimate_reassembly_payload_bytes_local(A_S, x, y, t, n_ratio_diag_xy)
% Estimate one cached restart payload size from its dominant numeric arrays.
    estimated_payload_bytes = ...
        estimate_numeric_array_bytes_local(A_S) + ...
        estimate_numeric_array_bytes_local(x) + ...
        estimate_numeric_array_bytes_local(y) + ...
        estimate_numeric_array_bytes_local(t) + ...
        estimate_numeric_array_bytes_local(n_ratio_diag_xy);
end

function bytes_out = estimate_numeric_array_bytes_local(x)
% Estimate storage size for one numeric/logical array without calling whos in the rebuild loop.
    if isempty(x) || ~(isnumeric(x) || islogical(x))
        bytes_out = 0;
        return;
    end
    if islogical(x) || isa(x, 'uint8') || isa(x, 'int8')
        bytes_per_element = 1;
    elseif isa(x, 'uint16') || isa(x, 'int16')
        bytes_per_element = 2;
    elseif isa(x, 'single') || isa(x, 'uint32') || isa(x, 'int32')
        bytes_per_element = 4;
    else
        bytes_per_element = 8;
    end
    if ~isreal(x)
        bytes_per_element = 2 * bytes_per_element;
    end
    bytes_out = double(numel(x)) * double(bytes_per_element);
end

function [axis_ok, max_abs_delta, tol, axis_detail] = compare_reassembly_grid_vector_local(ref_vec, cand_vec)
% Compare one physical grid vector with a tight absolute tolerance.
    axis_ok = true;
    max_abs_delta = 0;
    tol = 0;
    axis_detail = '';
    ref_col = double(ref_vec(:));
    cand_col = double(cand_vec(:));
    if numel(ref_col) ~= numel(cand_col)
        axis_ok = false;
        axis_detail = 'length_mismatch';
        max_abs_delta = NaN;
        tol = NaN;
        return;
    end
    if isequaln(ref_col, cand_col)
        return;
    end
    same_nan_mask = isnan(ref_col) & isnan(cand_col);
    finite_pair_mask = isfinite(ref_col) & isfinite(cand_col);
    if ~all(same_nan_mask | finite_pair_mask)
        axis_ok = false;
        axis_detail = 'nonfinite_layout_mismatch';
        max_abs_delta = NaN;
        tol = NaN;
        return;
    end
    ref_finite = ref_col(finite_pair_mask);
    cand_finite = cand_col(finite_pair_mask);
    if isempty(ref_finite)
        return;
    end
    max_abs_delta = max(abs(cand_finite - ref_finite), [], 'omitnan');
    ref_scale = max(abs(ref_finite), [], 'omitnan');
    if isempty(ref_scale) || ~isfinite(ref_scale)
        ref_scale = 0;
    end
    tol = max(1024 * eps(max(ref_scale, realmin('double'))), 1e-18);
    axis_ok = (max_abs_delta <= tol);
    if ~axis_ok
        axis_detail = 'value_mismatch';
    end
end

function diag = clear_reassembly_grid_ref_ctx_local(diag)
% Remove the hidden physical-grid reference context before publishing the public diag struct.
    if isfield(diag, 'reassembly_grid_ref_ctx')
        diag = rmfield(diag, 'reassembly_grid_ref_ctx');
    end
end

function save_reassembled_diag_local(diag, io_ctx)
% Save the reassembled diagnostics artifact through the shared MAT-save policy.
    if nargin < 2 || ~isstruct(io_ctx) || ~isfield(io_ctx, 'diag_output_file') || isempty(io_ctx.diag_output_file)
        error('assemble_diagnostics_from_restart:MissingDiagOutputFile', ...
            'io_ctx.diag_output_file must be provided before saving reassembled diagnostics.');
    end
    diag_output_file = char(string(io_ctx.diag_output_file));
    verify_saved_payload_flag = true;
    if isfield(io_ctx, 'verify_saved_payload_flag')
        verify_saved_payload_flag = struct_utils.normalize_bool_scalar( ...
            io_ctx.verify_saved_payload_flag, 'verify_saved_payload_flag', ...
            'CerUPP:InvalidVerifySavedPayloadFlag');
    end
    diag_bytes = 0;
    ws = whos('diag');
    if ~isempty(ws) && isfield(ws, 'bytes')
        diag_bytes = double(ws.bytes);
    end
    save_cfg = struct( ...
        'io_path', diag_output_file, ...
        'bytes_estimate', diag_bytes, ...
        'save_fn', @(mat_version_flag) checkpoint_utils.write_struct_payload_file( ...
            diag_output_file, struct('diag', diag), ...
            mat_version_flag, verify_saved_payload_flag), ...
        'phase_tag', 'end', ...
        'failure_tag', 'reassembled_diag_save', ...
        'warn_key', 'reassembled_diag_save_failed', ...
        'warn_id', 'CerUPP:RestartReassembly:ReassembledDiagSaveFailed', ...
        'warn_fmt', 'Reassembled diagnostics MAT save failed (%s): %s', ...
        'on_failure', 'throw');
    [~, save_ok] = checkpoint_utils.execute_mat_save_policy(save_cfg, struct());
    if ~save_ok
        error('assemble_diagnostics_from_restart:ReassembledDiagSaveUnexpectedState', ...
            'Shared MAT-save policy returned save_ok=false without throwing for %s.', diag_output_file);
    end
end

function arr = make_nan_array_local(sz, is_complex)
    if is_complex
        arr = complex(NaN(sz), NaN(sz));
    else
        arr = NaN(sz);
    end
end

function [band_ctx, issue_reason] = try_build_restart_band_masks_for_fund_diameter_local(rs, nt, checkpoint_name)
% Best-effort band-mask recovery for fundamental-band diameter rebuilds when RGB-band outputs are not requested.
    band_ctx = init_restart_band_mask_ctx_local(nt);
    issue_reason = '';
    try
        band_ctx = build_band_masks_local(rs, nt, checkpoint_name);
    catch me_band
        issue_reason = char(string(me_band.identifier));
        if isempty(issue_reason)
            issue_reason = 'band_mask_build_failed';
        end
        band_ctx.masks.fund_skip_reason = issue_reason;
    end
end

function [diameter_m, issue_reason] = rebuild_restart_beamcenter_tracked_diameter_local( ...
        x, y, fluence_xy, ix_bc, iy_bc)
% Mirror the live driver beam-center-tracked FWHM cut proxy from one rebuilt fluence map.
    diameter_m = NaN;
    issue_reason = '';
    if isempty(fluence_xy) || ~ismatrix(fluence_xy)
        return;
    end
    [nx_local, ny_local] = size(fluence_xy);
    if ~(isscalar(ix_bc) && isfinite(ix_bc) && ix_bc >= 1 && ix_bc <= nx_local && ...
            isscalar(iy_bc) && isfinite(iy_bc) && iy_bc >= 1 && iy_bc <= ny_local && ...
            ix_bc == round(ix_bc) && iy_bc == round(iy_bc))
        return;
    end
    [bw_x, bw_x_msg, bw_x_status] = filament_diagnostics_utils.fwhm_diameter_from_profile( ...
        x, fluence_xy(:, iy_bc));
    [bw_y, bw_y_msg, bw_y_status] = filament_diagnostics_utils.fwhm_diameter_from_profile( ...
        y, fluence_xy(ix_bc, :).');
    issue_parts = {};
    if bw_x_status.recoverable
        issue_parts{end+1} = sprintf('x:%s', bw_x_msg); %#ok<AGROW>
    end
    if bw_y_status.recoverable
        issue_parts{end+1} = sprintf('y:%s', bw_y_msg); %#ok<AGROW>
    end
    if ~isempty(issue_parts)
        issue_reason = strjoin(issue_parts, '; ');
    end
    bw_vals = [bw_x, bw_y];
    bw_vals = bw_vals(isfinite(bw_vals) & (bw_vals >= 0));
    if ~isempty(bw_vals)
        diameter_m = mean(bw_vals);
    end
end

function diag = assign_diag_field_local(diag, step, k, spec)
% Assign one rebuilt step payload into the canonical store slot for the resolved diag shape.
    field_name = spec.name;
    if ~isfield(step, field_name) || isempty(step.(field_name))
        return;
    end
    diag = ensure_diag_store_field_local(diag, spec);
    shape_descriptor = diag_shape_descriptor_local(spec);
    switch shape_descriptor
        case 'time_history_2d'
            diag.(field_name)(k, :) = step.(field_name);
        case 'xy_map_stack_3d'
            diag.(field_name)(:, :, k) = step.(field_name);
        case 'xy_spectral_cube_4d'
            diag.(field_name)(:, :, :, k) = step.(field_name);
        case 'xz_trace_2d'
            diag.(field_name)(:, k) = step.(field_name);
        case 'row_vector'
            diag.(field_name)(k) = step.(field_name);
        case 'column_vector'
            diag.(field_name)(k, :) = step.(field_name);
        case 'core_time_history_3d'
            diag.(field_name) = step.(field_name);
        otherwise
            error('assemble_diagnostics_from_restart:UnknownDiagFieldFamily', ...
                'Unknown diagnostic field shape "%s" for %s.', shape_descriptor, field_name);
    end
end

function band_ctx = build_band_masks_local(rs, nt, checkpoint_name)
% Rebuild restart spectral-band masks and their 1x1xNt broadcast views.
band_ctx = init_restart_band_mask_ctx_local(nt);

masks = band_ctx.masks;
has_masks = false;
if ~isfield(rs.grid, 'lambda_window') || isempty(rs.grid.lambda_window) || (numel(rs.grid.lambda_window) ~= nt)
    band_ctx.mask_skip_reason = 'lambda_window_missing_or_wrong_length';
    band_ctx.has_masks = false;
    return;
end

lambda_nm = rs.grid.lambda_window(:).' / (1e-9);
if any(~isfinite(lambda_nm))
    band_ctx.mask_skip_reason = 'lambda_window_nonfinite';
    band_ctx.has_masks = false;
    return;
end
diagnostic_band_cfg = extract_restart_diagnostic_band_cfg_local(rs, checkpoint_name);
lambda_visible_band_min = diagnostic_band_cfg.lambda_visible_band_min;
lambda_visible_band_max = diagnostic_band_cfg.lambda_visible_band_max;
lambda_blue_band_min = diagnostic_band_cfg.lambda_blue_band_min;
lambda_blue_band_max = diagnostic_band_cfg.lambda_blue_band_max;
lambda_green_band_min = diagnostic_band_cfg.lambda_green_band_min;
lambda_green_band_max = diagnostic_band_cfg.lambda_green_band_max;
lambda_red_band_min = diagnostic_band_cfg.lambda_red_band_min;
lambda_red_band_max = diagnostic_band_cfg.lambda_red_band_max;
lambda_fundamental_band_half_width = diagnostic_band_cfg.lambda_fundamental_band_half_width;

masks.vis = (lambda_nm >= lambda_visible_band_min) & (lambda_nm <= lambda_visible_band_max);
masks.blue = (lambda_nm >= lambda_blue_band_min) & (lambda_nm <= lambda_blue_band_max);
masks.green = (lambda_nm >= lambda_green_band_min) & (lambda_nm <= lambda_green_band_max);
masks.red = (lambda_nm >= lambda_red_band_min) & (lambda_nm <= lambda_red_band_max);
has_masks = true;

    [idx_fund, fund_ok, fund_reason] = resolve_explicit_restart_fund_idx_local(rs, nt);
if fund_ok
    lambda_fund_nm = lambda_nm(idx_fund);
    masks.fund = abs(lambda_nm - lambda_fund_nm) <= lambda_fundamental_band_half_width;
    masks.has_fund_mask = true;
else
    masks.fund_skip_reason = fund_reason;
end

band_ctx.masks = masks;
band_ctx.has_masks = has_masks;
band_ctx.vis_3d = reshape(masks.vis, 1, 1, []);
band_ctx.fund_3d = reshape(masks.fund, 1, 1, []);
band_ctx.red_3d = reshape(masks.red, 1, 1, []);
band_ctx.green_3d = reshape(masks.green, 1, 1, []);
band_ctx.blue_3d = reshape(masks.blue, 1, 1, []);
end

function diagnostic_band_cfg = extract_restart_diagnostic_band_cfg_local(rs, checkpoint_name)
% Validate the full saved diagnostic_band_cfg schema from the canonical
% resolved setup contract.
    range_msg = ['Restart checkpoint %s has inconsistent diagnostic_band_cfg ranges. ', ...
        'Rebuild checkpoints with the current driver before using restart diagnostics.'];
    run_meta = extract_restart_run_meta_local(rs);
    diagnostics_meta = extract_restart_setup_diagnostics_meta_local(run_meta);
    diagnostic_band_cfg_raw = struct_utils.opt_struct_field( ...
        diagnostics_meta, 'diagnostic_band_cfg', []);
    if isempty(diagnostic_band_cfg_raw)
        error('CerUPP:RestartDiagnosticBandCfgMissing', ...
            ['Restart checkpoint %s is missing resolved_setup_contract.diagnostics.diagnostic_band_cfg ', ...
             'Rebuild checkpoints with the current driver before using restart diagnostics.'], ...
            checkpoint_name);
    end
    diagnostic_band_cfg = driver_setup_support.validate_diagnostic_band_cfg( ...
        diagnostic_band_cfg_raw, checkpoint_name, ...
        'notstruct_id', 'CerUPP:RestartDiagnosticBandCfgInvalid', ...
        'notstruct_msg', ['Restart checkpoint %s has non-struct diagnostic_band_cfg metadata in ', ...
                          'resolved_setup_contract.diagnostics.'], ...
        'missing_id', 'CerUPP:RestartDiagnosticBandCfgInvalid', ...
        'missing_msg', 'Restart checkpoint %s is missing diagnostic_band_cfg field(s): %s.', ...
        'unknown_id', 'CerUPP:RestartDiagnosticBandCfgInvalid', ...
        'unknown_msg', 'Restart checkpoint %s has unexpected diagnostic_band_cfg field(s): %s.', ...
        'value_id', 'CerUPP:RestartDiagnosticBandCfgInvalid', ...
        'value_msg', 'Restart checkpoint %s has invalid diagnostic_band_cfg.%s=%s.', ...
        'range_id', 'CerUPP:RestartDiagnosticBandCfgInvalid', ...
        'visible_range_msg', range_msg, ...
        'blue_range_msg', range_msg, ...
        'green_range_msg', range_msg, ...
        'red_range_msg', range_msg, ...
        'fundamental_range_msg', range_msg);
end

function band_ctx = init_restart_band_mask_ctx_local(nt)
% Build the default empty restart band-mask bundle for one spectral grid length.
    masks = struct('vis', false(1, nt), 'fund', false(1, nt), ...
                   'red', false(1, nt), 'green', false(1, nt), 'blue', false(1, nt), ...
                   'has_fund_mask', false, 'fund_skip_reason', '');
    band_ctx = struct( ...
        'masks', masks, ...
        'has_masks', false, ...
        'mask_skip_reason', '', ...
        'vis_3d', reshape(masks.vis, 1, 1, []), ...
        'fund_3d', reshape(masks.fund, 1, 1, []), ...
        'red_3d', reshape(masks.red, 1, 1, []), ...
        'green_3d', reshape(masks.green, 1, 1, []), ...
        'blue_3d', reshape(masks.blue, 1, 1, []));
end

function fluence_xy = build_restart_weighted_fluence_from_masked_spectrum_local( ...
    masked_spectral_field, n_ratio_diag_xy, t, delta_t, fluence_use_parseval, weighted_intensity, spectral_power_raw, spectral_mask, parseval_time_grid_ok)
% Rebuild restart fluence with branch-specific weighting contracts:
% weighted_intensity is an optional fast path for the time-domain trapz
% branch, while Parseval mode ignores it and integrates from the masked
% spectrum plus n_ratio_diag_xy.
    if nargin < 6
        weighted_intensity = [];
    end
    if nargin < 7
        spectral_power_raw = [];
    end
    if nargin < 8
        spectral_mask = [];
    end
    if nargin < 9
        parseval_time_grid_ok = [];
    end
    use_parseval_effective = false;
    if logical(fluence_use_parseval)
        if isempty(parseval_time_grid_ok)
            parseval_time_grid_ok = filament_diagnostics_utils.time_grid_supports_parseval_fluence(t, delta_t);
        end
        use_parseval_effective = logical(parseval_time_grid_ok);
    end
    if ~use_parseval_effective && isempty(masked_spectral_field) && ~isempty(weighted_intensity)
        weighted_ndims = ndims(weighted_intensity);
        if ~(weighted_ndims == 3 || weighted_ndims == 4)
            error('CerUPP:InvalidRestartWeightedIntensityShape', ...
                'weighted_intensity must have ndims 3 or 4 for time-domain fluence; got ndims=%d.', ...
                weighted_ndims);
        end
        fluence_xy = trapz(t, weighted_intensity, 3);
        if weighted_ndims == 4
            fluence_xy = reshape(fluence_xy, size(weighted_intensity, 1), ...
                size(weighted_intensity, 2), size(weighted_intensity, 4));
        end
        return;
    end
    fluence_xy = band_diagnostics_utils.build_weighted_fluence_from_masked_spectrum( ...
        masked_spectral_field, n_ratio_diag_xy, t, delta_t, ...
        fluence_use_parseval, weighted_intensity, parseval_time_grid_ok, ...
        spectral_power_raw, spectral_mask);
end

function fluence_use_parseval = resolve_restart_fluence_use_parseval_local(rs)
% Resolve saved fluence metadata from the canonical strict-schema diagnostics owner.
    fluence_use_parseval = false;
    missing_field_label = ['run_meta.resolved_setup_contract.diagnostics.' ...
        '(fluence_method | fluence_use_parseval)'];
    run_meta = extract_restart_run_meta_local(rs);
    if isempty(run_meta)
        error('CerUPP:RestartMissingFluenceMethodMetadata', ...
            ['Restart payload is missing explicit fluence-method metadata (%s). ', ...
             'Rebuild checkpoints with current run_meta fluence provenance before using restart reassembly.'], ...
            missing_field_label);
    end
    diagnostics_meta = extract_restart_setup_diagnostics_meta_local(run_meta);
    chosen_methods = {};
    chosen_fields = {};
    if isstruct(diagnostics_meta)
        if isfield(diagnostics_meta, 'fluence_method')
            chosen_methods{end+1, 1} = require_restart_fluence_method_name_local( ... %#ok<AGROW>
                diagnostics_meta.fluence_method, ...
                'run_meta.resolved_setup_contract.diagnostics.fluence_method');
            chosen_fields{end+1, 1} = ...
                'run_meta.resolved_setup_contract.diagnostics.fluence_method'; %#ok<AGROW>
        end
        if isfield(diagnostics_meta, 'fluence_use_parseval')
            chosen_methods{end+1, 1} = ternary_restart_fluence_method_local( ... %#ok<AGROW>
                require_restart_scalar_logicalish_flag_local( ...
                diagnostics_meta.fluence_use_parseval, ...
                'run_meta.resolved_setup_contract.diagnostics.fluence_use_parseval'));
            chosen_fields{end+1, 1} = ...
                'run_meta.resolved_setup_contract.diagnostics.fluence_use_parseval'; %#ok<AGROW>
        end
    end
    if isempty(chosen_methods)
        error('CerUPP:RestartMissingFluenceMethodMetadata', ...
            ['Restart payload is missing explicit fluence-method metadata (%s). ', ...
             'Rebuild checkpoints with current run_meta fluence provenance before using restart reassembly.'], ...
            missing_field_label);
    end
    chosen_method = chosen_methods{1};
    if numel(unique(chosen_methods)) > 1
        raw_candidates = cell(numel(chosen_methods), 1);
        for ii = 1:numel(chosen_methods)
            raw_candidates{ii} = sprintf('%s=%s', chosen_fields{ii}, chosen_methods{ii});
        end
        error('CerUPP:RestartFluenceMethodMetadataDisagreement', ...
            ['Restart payload contains disagreeing canonical fluence-policy metadata (%s). ', ...
             'Rebuild checkpoints with one canonical fluence method before using restart reassembly.'], ...
            strjoin(raw_candidates, ', '));
    end
    fluence_use_parseval = strcmp(chosen_method, 'parseval');
end

function checkpoint_restart_compat_version = extract_restart_compat_version_local(rs, checkpoint_name)
% Read the canonical restart-version metadata from the strict-schema payload.
    checkpoint_restart_compat_version = NaN;
    if ~(isfield(rs, 'restart_compat_version') && ...
            isnumeric(rs.restart_compat_version) && isscalar(rs.restart_compat_version) && ...
            isfinite(rs.restart_compat_version))
        error('CerUPP:RestartCompatVersionMissing', ...
            ['Restart checkpoint %s is missing valid restart_compat_version metadata. ', ...
             'Rebuild checkpoints with the current driver before using the restart plotter.'], ...
            checkpoint_name);
    end
    checkpoint_restart_compat_version = double(rs.restart_compat_version);
    if round(checkpoint_restart_compat_version) ~= checkpoint_restart_compat_version
        error('CerUPP:RestartCompatVersionNonInteger', ...
            'Restart checkpoint %s has non-integer restart_compat_version=%s.', ...
            checkpoint_name, mat2str(checkpoint_restart_compat_version));
    end
end

function method = require_restart_fluence_method_name_local(method_raw, field_label)
% Require an explicit supported restart-held fluence-method string.
% Char or scalar-string input is trimmed/lowercased and must resolve to
% exactly 'parseval' or 'ifft_trapz'.
    method = 'ifft_trapz';
    if nargin < 2 || isempty(field_label)
        field_label = 'fluence_method';
    end
    if isstring(method_raw) && isscalar(method_raw)
        method_raw = char(method_raw);
    end
    if ~(ischar(method_raw) && isrow(method_raw))
        error('CerUPP:RestartInvalidFluenceMethod', ...
            '%s must be a char/string scalar.', field_label);
    end
    method = lower(strtrim(method_raw));
    if ~(strcmp(method, 'parseval') || strcmp(method, 'ifft_trapz'))
        error('CerUPP:RestartInvalidFluenceMethod', ...
            '%s must be ''parseval'' or ''ifft_trapz''; got ''%s''.', ...
            field_label, method_raw);
    end
end

function flag = require_restart_scalar_logicalish_flag_local(flag_raw, field_label)
% Require one scalar logical restart metadata flag: logical, or numeric 0/1.
    flag = false;
    if nargin < 2 || isempty(field_label)
        field_label = 'restart logical-like flag';
    end
    if islogical(flag_raw) && isscalar(flag_raw)
        flag = logical(flag_raw);
        return;
    end
    if isnumeric(flag_raw) && isreal(flag_raw) && isscalar(flag_raw) && ...
            isfinite(flag_raw) && ((flag_raw == 0) || (flag_raw == 1))
        flag = logical(flag_raw);
        return;
    end
    error('CerUPP:RestartInvalidFluenceMethodFlag', ...
        '%s must be a scalar logical or numeric in {0,1}.', field_label);
end

function status_text = assemble_reassembly_status_text_local(status_code, status_detail)
% Derive one compact human-readable status string from code/detail fields.
    status_code = char(string(status_code));
    status_detail = char(string(status_detail));
    status_text = status_code;
    if ~isempty(status_detail)
        status_text = sprintf('%s:%s', status_code, status_detail);
    end
end

function run_meta = extract_restart_run_meta_local(rs)
% Centralize restart run_meta access without duplicating downstream schema parsing.
    run_meta = [];
    if isfield(rs, 'meta') && isstruct(rs.meta) && ...
            isfield(rs.meta, 'run_meta') && isstruct(rs.meta.run_meta)
        run_meta = rs.meta.run_meta;
    end
end

function rebuild_flags = resolve_restart_rebuild_output_flags_local(rs, rebuild_policy)
% Resolve optional restart rebuild families against the canonical saved run-output intent.
    if nargin < 2 || isempty(rebuild_policy) || ~isstruct(rebuild_policy)
        rebuild_policy = normalize_reassembly_rebuild_policy_local( ...
            {'core', 'bands_rgb', 'full_spectrum', 'plasma_nla'}, true);
    end
    run_meta = extract_restart_run_meta_local(rs);
    if isempty(run_meta) || ~isstruct(run_meta)
        error('CerUPP:RestartMissingOutputPolicyMetadata', ...
            ['Restart payload is missing run_meta.resolved_setup_contract.diagnostics. ', ...
             'Rebuild checkpoints with the current driver before using restart reassembly.']);
    end
    diagnostics_meta = extract_restart_setup_diagnostics_meta_local(run_meta);
    if ~isstruct(diagnostics_meta) || isempty(fieldnames(diagnostics_meta))
        error('CerUPP:RestartMissingOutputPolicyMetadata', ...
            ['Restart payload is missing canonical diagnostics metadata under ', ...
             'run_meta.resolved_setup_contract.diagnostics.']);
    end
    store_diag_plan = struct_utils.opt_struct_field(diagnostics_meta, 'store_diag_plan', []);
    if ~(isstruct(store_diag_plan) && ~isempty(fieldnames(store_diag_plan)))
        error('CerUPP:RestartStoreDiagPlanMissing', ...
            ['Restart checkpoint is missing run_meta.resolved_setup_contract.diagnostics.store_diag_plan. ', ...
             'Rebuild checkpoints with the current driver before using restart reassembly.']);
    end
    required_plan_fields = { ...
        'need_store_spectral_intens_cube', ...
        'need_visible_band_store', ...
        'need_fund_band_store', ...
        'need_visible_fluence_store', ...
        'need_rgb_final_plots'};
    plan_flags = struct();
    for ii = 1:numel(required_plan_fields)
        field_name = required_plan_fields{ii};
        field_label = ['run_meta.resolved_setup_contract.diagnostics.store_diag_plan.' field_name];
        if ~isfield(store_diag_plan, field_name)
            error('CerUPP:RestartStoreDiagPlanMissingField', ...
                'Restart checkpoint is missing canonical %s.', field_label);
        end
        plan_flags.(field_name) = require_restart_scalar_logicalish_flag_local( ...
            store_diag_plan.(field_name), field_label);
    end
    resolved_output_policy = struct_utils.opt_struct_field( ...
        diagnostics_meta, 'resolved_output_policy', struct());
    effective_output_policy = struct_utils.opt_struct_field( ...
        resolved_output_policy, 'effective', struct());
    if ~(isstruct(effective_output_policy) && isfield(effective_output_policy, 'store_spectral_fluence_flag'))
        error('CerUPP:RestartResolvedOutputPolicyMissingField', ...
            ['Restart checkpoint is missing canonical ', ...
             'run_meta.resolved_setup_contract.diagnostics.resolved_output_policy.effective.store_spectral_fluence_flag.']);
    end
    store_spectral_fluence_flag = require_restart_scalar_logicalish_flag_local( ...
        effective_output_policy.store_spectral_fluence_flag, ...
        'run_meta.resolved_setup_contract.diagnostics.resolved_output_policy.effective.store_spectral_fluence_flag');
    rgb_history_requested_flag = logical( ...
        plan_flags.need_visible_band_store || ...
        plan_flags.need_fund_band_store || ...
        plan_flags.need_visible_fluence_store || ...
        plan_flags.need_rgb_final_plots || ...
        store_spectral_fluence_flag);
    full_spectrum_requested_flag = logical(plan_flags.need_store_spectral_intens_cube);
    rebuild_flags = struct( ...
        'bands_rgb', logical(rebuild_policy.bands_rgb), ...
        'rgb_history', logical(rebuild_policy.bands_rgb) && resolve_restart_optional_rebuild_gate_local( ...
            rebuild_policy.explicit_bands_rgb_request, ...
            rgb_history_requested_flag), ...
        'full_spectrum', logical(rebuild_policy.full_spectrum) && resolve_restart_optional_rebuild_gate_local( ...
            rebuild_policy.explicit_full_spectrum_request, ...
            full_spectrum_requested_flag), ...
        'plasma_nla', logical(rebuild_policy.plasma_nla));
end

function allow_rebuild = resolve_restart_optional_rebuild_gate_local(explicit_request, stored_flag)
% Prefer explicit caller request, then saved run intent.
    if logical(explicit_request)
        allow_rebuild = true;
    elseif ~isempty(stored_flag)
        allow_rebuild = logical(stored_flag);
    else
        allow_rebuild = false;
    end
end

function diagnostics_meta = extract_restart_setup_diagnostics_meta_local(run_meta)
% Read canonical restart diagnostics metadata from the strict-schema setup contract.
    diagnostics_meta = struct();
    if nargin < 1 || ~isstruct(run_meta)
        return;
    end
    resolved_setup_contract = struct_utils.opt_struct_field(run_meta, 'resolved_setup_contract', []);
    if isstruct(resolved_setup_contract)
        diagnostics_meta = struct_utils.opt_struct_field(resolved_setup_contract, 'diagnostics', struct());
        if isstruct(diagnostics_meta) && ~isempty(fieldnames(diagnostics_meta))
            return;
        end
    end
end

function [n_ratio_diag_xy, ok, reason, note] = build_restart_diag_weight_map_local(rs, nx, ny, nt, like_template)
% Rebuild n(x,y,omega_fund)/n_ref from saved lin_index_3d layouts [Nx Ny],
% [Nx Ny 1], or [Nx Ny Nt]; the full 3-D case resolves the fundamental bin
% via resolve_explicit_restart_fund_idx_local. Invalid/nonpositive weights
% are treated as an unavailable diagnostic-weight map (ok=false) rather
% than being silently repaired.
    n_ratio_diag_xy = [];
    ok = false;
    reason = '';
    note = '';
    if ~isfield(rs.medium, 'lin_index_3d') || isempty(rs.medium.lin_index_3d)
        reason = 'missing_lin_index_3d';
        return;
    end
    if ~isfield(rs.medium, 'n_Sell_fund') || isempty(rs.medium.n_Sell_fund)
        reason = 'missing_n_Sell_fund';
        return;
    end
    if ~(isnumeric(rs.medium.n_Sell_fund) && isscalar(rs.medium.n_Sell_fund))
        reason = 'invalid_n_Sell_fund_type';
        return;
    end
    if ~isreal(rs.medium.n_Sell_fund)
        reason = 'complex_n_Sell_fund';
        return;
    end
    n_ref_diag = double(rs.medium.n_Sell_fund);
    if ~(isfinite(n_ref_diag) && (n_ref_diag > 0))
        reason = 'invalid_n_Sell_fund';
        return;
    end

    lin_index_3d = rs.medium.lin_index_3d;
    if isequal(size(lin_index_3d), [nx, ny])
        n_omega_fund_xy = lin_index_3d;
    elseif isequal(size(lin_index_3d), [nx, ny, 1])
        n_omega_fund_xy = lin_index_3d(:, :, 1);
    elseif isequal(size(lin_index_3d), [1, 1, nt])
        [idx_fund, idx_ok, idx_reason] = resolve_explicit_restart_fund_idx_local(rs, nt);
        if ~idx_ok
            reason = idx_reason;
            return;
        end
        n_omega_fund_xy = lin_index_3d(:, :, idx_fund) + zeros(nx, ny, 'like', lin_index_3d);
    elseif isequal(size(lin_index_3d), [nx, ny, nt])
        [idx_fund, idx_ok, idx_reason] = resolve_explicit_restart_fund_idx_local(rs, nt);
        if ~idx_ok
            reason = idx_reason;
            return;
        end
        n_omega_fund_xy = lin_index_3d(:, :, idx_fund);
    else
        reason = sprintf('unsupported_lin_index_shape_%s', mat2str(size(lin_index_3d)));
        return;
    end

    if ~(isnumeric(n_omega_fund_xy) && isequal(size(n_omega_fund_xy), [nx, ny]))
        reason = 'invalid_lin_index_fund_slice_type';
        return;
    end
    if ~isreal(n_omega_fund_xy)
        reason = 'complex_lin_index_fund_slice';
        return;
    end
    if any(~isfinite(n_omega_fund_xy(:)))
        reason = 'invalid_lin_index_fund_slice';
        return;
    end

    like_real = real(like_template);
    if isempty(like_real)
        like_real = 1;
    end
    n_ratio_diag_xy = cast(double(n_omega_fund_xy), 'like', like_real) ./ cast(n_ref_diag, 'like', like_real);
    bad = ~isfinite(n_ratio_diag_xy) | (n_ratio_diag_xy <= 0);
    if any(bad(:))
        note = sprintf('diag_weight_invalid=%d', nnz(bad));
        reason = 'invalid_diag_weight_values';
        n_ratio_diag_xy = [];
        return;
    end
    ok = true;
end

function [idx_fund, ok, reason] = resolve_explicit_restart_fund_idx_local(rs, nt)
% Resolve one canonical fundamental-bin index for restart reassembly.
% When both explicit lambda_fund and omega_fund metadata are present, they
% must resolve to the same discrete bin or the helper rejects the payload.
    idx_fund = NaN;
    ok = false;
    reason = 'missing_explicit_lambda_fund_or_omega_fund';
    [idx_lambda, lambda_ok, lambda_reason] = resolve_restart_fund_idx_from_axis_local( ...
        struct_utils.opt_struct_field(rs.grid, 'lambda_fund', []), ...
        struct_utils.opt_struct_field(rs.grid, 'lambda_window', []), nt, 'lambda');
    [idx_omega, omega_ok, omega_reason] = resolve_restart_fund_idx_from_axis_local( ...
        struct_utils.opt_struct_field(rs.grid, 'omega_fund', []), ...
        struct_utils.opt_struct_field(rs.grid, 'omega_window', []), nt, 'omega');
    if lambda_ok && omega_ok
        if idx_lambda ~= idx_omega
            reason = sprintf('fund_metadata_bin_mismatch_lambda_%d_omega_%d', idx_lambda, idx_omega);
            return;
        end
        idx_fund = idx_omega;
        ok = true;
        reason = '';
        return;
    end
    if omega_ok
        idx_fund = idx_omega;
        ok = true;
        reason = '';
        return;
    end
    if lambda_ok
        idx_fund = idx_lambda;
        ok = true;
        reason = '';
        return;
    end
    reason = join_issue_reasons_local(lambda_reason, omega_reason);
end

function [idx_fund, ok, reason] = resolve_restart_fund_idx_from_axis_local(fund_value_raw, axis_raw, nt, axis_label)
% Resolve one fundamental-bin candidate from an explicit scalar carrier value and its axis.
    idx_fund = NaN;
    ok = false;
    reason = sprintf('missing_%s_fund_or_%s_window', axis_label, axis_label);
    if isempty(fund_value_raw) || isempty(axis_raw)
        return;
    end
    if ~(isnumeric(axis_raw) && isvector(axis_raw))
        reason = sprintf('invalid_%s_window_type', axis_label);
        return;
    end
    if ~isreal(axis_raw)
        reason = sprintf('complex_%s_window', axis_label);
        return;
    end
    axis = double(axis_raw(:).');
    if numel(axis) ~= nt
        reason = sprintf('invalid_%s_window_length', axis_label);
        return;
    end
    if any(~isfinite(axis))
        reason = sprintf('invalid_%s_window', axis_label);
        return;
    end
    if ~(isnumeric(fund_value_raw) && isscalar(fund_value_raw))
        reason = sprintf('invalid_%s_fund_type', axis_label);
        return;
    end
    if ~isreal(fund_value_raw)
        reason = sprintf('complex_%s_fund', axis_label);
        return;
    end
    fund_value = double(fund_value_raw);
    if ~isfinite(fund_value)
        reason = sprintf('invalid_%s_fund', axis_label);
        return;
    end
    axis_sorted = sort(axis, 'ascend');
    axis_gap = diff(axis_sorted);
    if any(axis_gap <= 0)
        reason = sprintf('nonunique_%s_window_bins', axis_label);
        return;
    end
    tol_abs = resolve_restart_axis_match_tolerance_local(axis_sorted, fund_value);
    if (fund_value < (axis_sorted(1) - tol_abs)) || (fund_value > (axis_sorted(end) + tol_abs))
        reason = sprintf('%s_fund_out_of_band', axis_label);
        return;
    end
    match_mask = abs(axis - fund_value) <= tol_abs;
    if ~any(match_mask)
        reason = sprintf('%s_fund_not_on_axis', axis_label);
        return;
    end
    if nnz(match_mask) ~= 1
        reason = sprintf('nonunique_%s_fund_axis_match', axis_label);
        return;
    end
    idx_fund = find(match_mask, 1, 'first');
    ok = true;
    reason = '';
end

function tol_abs = resolve_restart_axis_match_tolerance_local(axis_sorted, fund_value)
% Resolve a tiny absolute tolerance for matching a scalar carrier metadata
% value onto one stored restart axis bin. Tolerance is anchored to machine
% precision and to the local axis spacing so only roundoff-scale drift is
% accepted.
    scale = max([1, abs(double(fund_value)), max(abs(double(axis_sorted)))]);
    tol_abs = 1024 * eps(scale);
    if numel(axis_sorted) >= 2
        positive_gap = diff(double(axis_sorted));
        positive_gap = positive_gap(isfinite(positive_gap) & (positive_gap > 0));
        if ~isempty(positive_gap)
            tol_abs = max(tol_abs, 1e-9 * min(positive_gap));
        end
    end
end

function [full_arr, ok, reason] = expand_core_or_full_td_local(arr_in, rs, nx, ny, nt, fill_value)
% Expand time-domain arrays with three outcomes: pass through already-full
% [Nx Ny Nt] inputs unchanged, expand core-only [Nc Nt] inputs to full size
% with non-core cells filled by fill_value, or return ok=false plus a
% reason code for unsupported shapes/bad core_idx state.
full_arr = [];
ok = false;
reason = '';
if isempty(arr_in)
    return;
end

if isequal(size(arr_in), [nx, ny, nt])
    full_arr = arr_in;
    ok = true;
    return;
end

if ~(ismatrix(arr_in) && (size(arr_in, 2) == nt))
    reason = sprintf('unsupported_shape_%s', mat2str(size(arr_in)));
    return;
end

[core_idx, core_idx_ok, core_idx_reason] = ...
    validate_restart_core_idx_local(rs, nx * ny, size(arr_in, 1));
if ~core_idx_ok
    reason = core_idx_reason;
    return;
end

full_flat = fill_value * ones(nx * ny, nt, 'like', arr_in);
try
    full_flat(core_idx, :) = arr_in;
catch me
    reason = sprintf('indexed_assignment_failed:%s', me.identifier);
    ok = false;
    return;
end
full_arr = reshape(full_flat, nx, ny, nt);
ok = true;
end

function [core_idx, ok, reason] = validate_restart_core_idx_local(rs, nxy, expected_count)
% Validate restart core_idx against the shared exact compact-core contract.
core_idx = [];
ok = false;
reason = '';
if nargin < 3 || isempty(expected_count)
    expected_count = [];
end
if ~isfield(rs, 'medium') || ~isstruct(rs.medium) || ...
        ~isfield(rs.medium, 'core_idx') || isempty(rs.medium.core_idx)
    reason = 'missing_core_idx';
    return;
end
core_idx = double(rs.medium.core_idx(:));
if ~(all(isfinite(core_idx)) && all(core_idx >= 1) && all(core_idx <= nxy) && ...
        all(core_idx == round(core_idx)) && ...
        (numel(unique(core_idx)) == numel(core_idx)))
    core_idx = [];
    reason = 'invalid_core_idx';
    return;
end
if ~isempty(expected_count) && (numel(core_idx) ~= double(expected_count))
    core_idx = [];
    reason = 'invalid_core_idx';
    return;
end
ok = true;
end

function [core_rows, core_idx, ok, reason] = get_core_td_rows_local(arr_in, rs, nx, ny, nt)
% Return canonical [Nc,Nt] core rows when arr_in uses the compact core-only shape.
core_rows = [];
core_idx = [];
ok = false;
reason = '';
if isempty(arr_in)
    return;
end
if isequal(size(arr_in), [nx, ny, nt])
    reason = 'already_full';
    return;
end
if ~(ismatrix(arr_in) && (size(arr_in, 2) == nt))
    reason = sprintf('unsupported_shape_%s', mat2str(size(arr_in)));
    return;
end
[core_idx, core_idx_ok, core_idx_reason] = ...
    validate_restart_core_idx_local(rs, nx * ny, size(arr_in, 1));
if ~core_idx_ok
    reason = core_idx_reason;
    core_idx = [];
    return;
end
core_rows = arr_in;
ok = true;
end

function [core_vec, core_idx, ok, reason] = get_core_vec_local(arr_in, rs, nx, ny)
% Return canonical [Nc,1] core vectors when arr_in uses the compact core-only shape.
core_vec = [];
core_idx = [];
ok = false;
reason = '';
if isempty(arr_in)
    return;
end
if ~isvector(arr_in)
    reason = sprintf('unsupported_shape_%s', mat2str(size(arr_in)));
    return;
end
arr_col = arr_in(:);
[core_idx, core_idx_ok, core_idx_reason] = ...
    validate_restart_core_idx_local(rs, nx * ny, numel(arr_col));
if ~core_idx_ok
    reason = core_idx_reason;
    core_idx = [];
    return;
end
core_vec = arr_col;
ok = true;
end

function [axis_rows, ok, reason] = extract_core_td_axis_rows_local(core_rows, core_idx, nx, ny, iy_axis0, fill_value)
% Scatter a compact [Nc,Nt] core-only tensor onto one axis-nearest y slice without full-cube expansion.
axis_rows = [];
ok = false;
reason = '';
if isempty(core_rows) || isempty(core_idx)
    reason = 'missing_core_rows';
    return;
end
nt = size(core_rows, 2);
axis_rows = fill_value * ones(nx, nt, 'like', core_rows);
axis_lin_idx = sub2ind([nx, ny], (1:nx).', repmat(iy_axis0, nx, 1));
[is_on_axis, core_row_idx] = ismember(axis_lin_idx, core_idx(:));
if ~any(is_on_axis)
    axis_rows = [];
    reason = 'axis_not_in_core';
    return;
end
axis_rows(is_on_axis, :) = core_rows(core_row_idx(is_on_axis), :);
ok = true;
end

function [core_rows, core_idx, ok, reason] = get_exact_valid_core_rows_local(book_struct, rs, nx, ny, nt)
% Return validated logical exact-valid core rows; reject non-binary numeric masks.
    [core_rows_raw, core_idx, ok, reason] = get_core_td_rows_local( ...
        opt_restart_book_field_local(book_struct, 'exact_valid_core'), rs, nx, ny, nt);
    if ~ok
        core_rows = [];
        core_idx = [];
        return;
    end
    [core_rows, values_ok, values_reason] = normalize_restart_exact_valid_mask_local(core_rows_raw);
    if ~values_ok
        core_rows = [];
        core_idx = [];
        ok = false;
        reason = values_reason;
    end
end

function [valid_mask, ok, reason] = normalize_restart_exact_valid_mask_local(valid_in)
% Accept only logical arrays or numeric arrays containing finite {0,1} values.
    valid_mask = [];
    ok = false;
    reason = '';
    if islogical(valid_in)
        valid_mask = logical(valid_in);
        ok = true;
        return;
    end
    if ~(isnumeric(valid_in) && isreal(valid_in))
        reason = sprintf('invalid_exact_valid_core_type_%s', class(valid_in));
        return;
    end
    valid_numeric = double(valid_in);
    if any(~isfinite(valid_numeric(:)))
        reason = 'nonfinite_exact_valid_core';
        return;
    end
    if any((valid_numeric(:) ~= 0) & (valid_numeric(:) ~= 1))
        reason = 'nonbinary_exact_valid_core';
        return;
    end
    valid_mask = logical(valid_numeric);
    ok = true;
end

function [dt, ok, reason] = infer_delta_t_local(t)
% Require a finite strictly increasing near-uniform time grid before FFT-scaled rebuilds.
dt = NaN;
ok = false;
reason = 'time_grid_too_short';
if numel(t) < 2
    return;
end
t_col = double(t(:));
if any(~isfinite(t_col)) || ~isreal(t_col)
    reason = 'nonfinite_time_grid';
    return;
end
dt_vec = diff(t_col);
if any(~isfinite(dt_vec))
    reason = 'nonfinite_time_spacing';
    return;
end
if any(dt_vec <= 0)
    reason = 'time_grid_not_strictly_increasing';
    return;
end
dt = median(dt_vec);
if ~(isfinite(dt) && (dt > 0))
    dt = NaN;
    reason = 'invalid_time_spacing';
    return;
end
uniform_tol = max(1e-12, 1e-6 * max(abs(dt), 1));
if any(abs(dt_vec - dt) > uniform_tol)
    dt = NaN;
    reason = 'time_grid_not_uniform';
    return;
end
ok = true;
reason = '';
end

function value = opt_restart_book_field_local(book_struct, field_name)
% Return book_struct.(field_name) when present; otherwise [] for
% missing-field or non-struct inputs.
value = [];
if isstruct(book_struct) && isfield(book_struct, field_name)
    value = book_struct.(field_name);
end
end

function [valid_full, ok, reason, invalid_count] = expand_exact_valid_core_local(book_struct, rs, nx, ny, nt)
% Expand checkpoint exact-valid masks before using exact/applied ledgers.
valid_full = false(nx, ny, nt);
ok = false;
reason = '';
invalid_count = 0;
if ~isstruct(book_struct)
    reason = 'missing_exact_valid_core';
    return;
end
valid_in = opt_restart_book_field_local(book_struct, 'exact_valid_core');
if isempty(valid_in)
    reason = 'missing_exact_valid_core';
    return;
end
[valid_in, values_ok, values_reason] = normalize_restart_exact_valid_mask_local(valid_in);
if ~values_ok
    reason = values_reason;
    return;
end
invalid_count = nnz(~logical(valid_in(:)));
[valid_full_raw, ok_expand, expand_reason] = expand_core_or_full_td_local(valid_in, rs, nx, ny, nt, 0);
if ~ok_expand
    reason = sprintf('exact_valid_core_%s', expand_reason);
    return;
end
valid_full = logical(valid_full_raw);
ok = true;
end

function issue_text = join_issue_reasons_local(varargin)
% Join nonempty restart partial-issue fragments with one stable separator.
parts = cell(0, 1);
for idx_part = 1:nargin
    part = varargin{idx_part};
    if isstring(part)
        if ~isscalar(part)
            continue;
        end
        part = char(part);
    end
    if ischar(part)
        part = strtrim(part);
        if ~isempty(part)
            parts{end+1, 1} = part; %#ok<AGROW>
        end
    end
end
issue_text = '';
if ~isempty(parts)
    issue_text = strjoin(parts, ' | ');
end
end

function [dt_row, ok, reason] = infer_restart_dt_row_local(rs, t, nt, like_template)
% Build the driver-style [1 x Nt] dt row used for applied increment -> rate conversion.
dt_row = zeros(1, nt, 'like', like_template);
ok = false;
reason = '';
dt_vec = [];
if isfield(rs, 'grid') && isstruct(rs.grid) && isfield(rs.grid, 'dt_vec') && ~isempty(rs.grid.dt_vec)
    dt_vec = rs.grid.dt_vec(:);
elseif numel(t) >= 2
    dt_vec = diff(t(:));
end
if isempty(dt_vec)
    reason = 'missing_dt_vec';
    return;
end
if numel(dt_vec) ~= max(nt - 1, 0)
    reason = sprintf('dt_length_mismatch_%d', numel(dt_vec));
    return;
end
if any(~isfinite(dt_vec)) || any(dt_vec <= 0)
    reason = 'invalid_dt_values';
    return;
end
if nt >= 2
    dt_row(2:end) = cast(dt_vec(:).', 'like', dt_row);
end
ok = true;
end

function rate_full = applied_increment_to_rate_local(increment_full, dt_row)
% Convert applied per-step increments to per-time-sample rates.
% Divide only where dt_row is finite and strictly positive; other samples
% retain zero in rate_full.
rate_full = zeros(size(increment_full), 'like', increment_full);
valid_dt = isfinite(dt_row) & (dt_row > 0);
if any(valid_dt)
    if ismatrix(increment_full)
        denom = reshape(dt_row(valid_dt), 1, []);
        rate_full(:, valid_dt) = increment_full(:, valid_dt) ./ denom;
    else
        denom = reshape(dt_row(valid_dt), 1, 1, []);
        rate_full(:, :, valid_dt) = increment_full(:, :, valid_dt) ./ denom;
    end
end
end

function prefix = conditional_prefix_local(cond, prefix_text)
% Small formatting helper for partial-issue messages.
prefix = '';
if cond
    prefix = prefix_text;
end
end

function [ds, ok, reason] = infer_grid_step_local(v, grid_name)
% Require a finite strictly increasing near-uniform spatial grid before FFT-scaled rebuilds.
if nargin < 2 || isempty(grid_name)
    grid_name = 'grid';
end
ds = NaN;
ok = false;
reason = sprintf('%s_too_short', grid_name);
if numel(v) < 2
    return;
end
v_col = double(v(:));
if any(~isfinite(v_col)) || ~isreal(v_col)
    reason = sprintf('%s_nonfinite_values', grid_name);
    return;
end
dv = diff(v_col);
if any(~isfinite(dv))
    reason = sprintf('%s_nonfinite_spacing', grid_name);
    return;
end
if any(dv <= 0)
    reason = sprintf('%s_not_strictly_increasing', grid_name);
    return;
end
ds = median(dv);
if ~(isfinite(ds) && (ds > 0))
    ds = NaN;
    reason = sprintf('%s_invalid_spacing', grid_name);
    return;
end
uniform_tol = max(1e-12, 1e-6 * max(abs(ds), 1));
if any(abs(dv - ds) > uniform_tol)
    ds = NaN;
    reason = sprintf('%s_not_uniform', grid_name);
    return;
end
ok = true;
reason = '';
end

function [inv_vg, reason, source_tag] = infer_inv_vg_local(rs)
% Fallback-only inv_vg reconstruction from n(omega). Fresh sibling full
% checkpoints should provide the stored scalar directly.
inv_vg = NaN;
reason = '';
source_tag = '';
if ~isfield(rs.medium, 'n_Sell') || ~isfield(rs.grid, 'omega_window') || ...
        isempty(rs.medium.n_Sell) || isempty(rs.grid.omega_window) || ...
        (numel(rs.medium.n_Sell) ~= numel(rs.grid.omega_window))
    reason = 'missing_or_mismatched_n_sell_or_omega_window';
    return;
end

if ~isnumeric(rs.grid.omega_window) || ~isnumeric(rs.medium.n_Sell)
    reason = 'invalid_n_sell_or_omega_window_type';
    return;
end
if ~isreal(rs.grid.omega_window)
    reason = 'complex_omega_window';
    return;
end
if ~isreal(rs.medium.n_Sell)
    reason = 'complex_n_sell';
    return;
end

omega = double(rs.grid.omega_window(:));
n_sell = double(rs.medium.n_Sell(:));
if any(~isfinite(omega)) || any(~isfinite(n_sell))
    reason = 'nonfinite_n_sell_or_omega_window';
    return;
end

if numel(omega) < 2
    reason = 'insufficient_omega_samples';
    return;
end

% omega_window is stored in FFT-native ordering. Build the monotonic view
% needed for differentiation from that canonical ordering, but reject
% duplicated bins rather than silently deduplicating them.
[omega_sorted, idx_sort] = sort(omega, 'ascend');
n_sell_sorted = n_sell(idx_sort);
if any(diff(omega_sorted) <= 0)
    reason = 'nonunique_omega_window_bins';
    return;
end

c = 299792458;
k_sorted = n_sell_sorted .* omega_sorted / c;
dk_domega_sorted = gradient(k_sorted, omega_sorted);

omega_fund_raw = struct_utils.opt_struct_field(rs.grid, 'omega_fund', []);
if isnumeric(omega_fund_raw) && isreal(omega_fund_raw) && ...
        isscalar(omega_fund_raw) && isfinite(double(omega_fund_raw))
    omega_fund = double(omega_fund_raw);
    inv_vg_interp = real(spline(omega_sorted, dk_domega_sorted, omega_fund));
    if isfinite(inv_vg_interp)
        inv_vg = inv_vg_interp;
        source_tag = 'inferred_from_nomega_spline_omega_fund';
    else
        reason = 'nonfinite_spline_inferred_inv_vg';
    end
    return;
end

[idx_fund_raw, idx_ok, ~] = resolve_explicit_restart_fund_idx_local(rs, numel(omega));
if ~idx_ok
    reason = 'missing_restart_fund_idx';
    return;
end
idx_fund_sorted = find(idx_sort(:) == idx_fund_raw, 1, 'first');
if isempty(idx_fund_sorted)
    reason = 'restart_fund_idx_not_found_after_sort';
    return;
end
idx_fund_sorted = max(1, min(numel(dk_domega_sorted), round(double(idx_fund_sorted))));
if isfinite(dk_domega_sorted(idx_fund_sorted))
    inv_vg = dk_domega_sorted(idx_fund_sorted);
    source_tag = 'inferred_from_nomega_nearest_fund_bin';
else
    reason = 'nonfinite_inferred_inv_vg';
end
end

function [inv_vg, source_tag, partial_reason] = resolve_restart_store_inv_vg_local( ...
    rs, checkpoint_dir, checkpoint_name)
% Prefer a stored store_inv_vg scalar from the sibling full checkpoint when available.
    inv_vg = NaN;
    source_tag = '';
    partial_reason = '';
    [stored_inv_vg, stored_ok, stored_reason] = extract_restart_store_inv_vg_from_fullsave_local( ...
        rs, checkpoint_dir, checkpoint_name);
    if stored_ok
        inv_vg = stored_inv_vg;
        source_tag = 'stored_fullsave';
        return;
    end
    if ~isempty(stored_reason)
        partial_reason = stored_reason;
    end
    [inv_vg, infer_reason, inferred_source_tag] = infer_inv_vg_local(rs);
    if ~isempty(infer_reason)
        partial_reason = join_issue_reasons_local(partial_reason, infer_reason);
    end
    if isfinite(inv_vg) && (inv_vg > 0)
        source_tag = inferred_source_tag;
    else
        source_tag = 'unavailable';
    end
end

function [stored_inv_vg, ok, reason] = extract_restart_store_inv_vg_from_fullsave_local(rs, checkpoint_dir, checkpoint_name)
% Load the stored store_inv_vg column from the sibling full checkpoint for this restart slice.
    stored_inv_vg = NaN;
    ok = false;
    reason = '';
    fullsave_name = restart_fullsave_sibling_name_local(checkpoint_name);
    if isempty(fullsave_name)
        reason = 'sibling_fullsave_name_unavailable';
        return;
    end
    fullsave_path = fullfile(checkpoint_dir, fullsave_name);
    if exist(fullsave_path, 'file') ~= 2
        reason = 'sibling_fullsave_missing';
        return;
    end
    try
        s = load(fullsave_path, 'store_inv_vg');
    catch
        reason = 'sibling_fullsave_load_failed';
        return;
    end
    if ~isfield(s, 'store_inv_vg') || isempty(s.store_inv_vg)
        reason = 'sibling_fullsave_missing_store_inv_vg';
        return;
    end
    store_idx = extract_restart_store_idx_local(rs);
    store_inv_vg = s.store_inv_vg;
    if ~(isnumeric(store_inv_vg) && isreal(store_inv_vg))
        reason = 'sibling_fullsave_invalid_store_inv_vg_type';
        return;
    end
    if isscalar(store_inv_vg)
        stored_inv_vg = double(store_inv_vg);
    else
        if ~(isfinite(store_idx) && (store_idx >= 1) && (store_idx == fix(store_idx)) && ...
                (store_idx <= numel(store_inv_vg)))
            reason = 'sibling_fullsave_store_idx_mismatch';
            return;
        end
        stored_inv_vg = double(store_inv_vg(store_idx));
    end
    if ~(isfinite(stored_inv_vg) && (stored_inv_vg > 0))
        reason = 'sibling_fullsave_invalid_store_inv_vg_value';
        stored_inv_vg = NaN;
        return;
    end
    ok = true;
end

function store_idx = extract_restart_store_idx_local(rs)
% Extract the saved store-plane index for selecting one checkpoint-sibling history column.
    store_idx = NaN;
    if isfield(rs, 'progress') && isstruct(rs.progress) && ...
            isfield(rs.progress, 'store_idx') && isfinite(rs.progress.store_idx)
        store_idx = double(rs.progress.store_idx);
    end
end

function fullsave_name = restart_fullsave_sibling_name_local(checkpoint_name)
% Map a restart checkpoint filename onto its sibling full-checkpoint filename.
    fullsave_name = '';
    if ~ischar(checkpoint_name)
        checkpoint_name = char(string(checkpoint_name));
    end
    if strcmp(checkpoint_name, 'checkpoint_latest.mat')
        fullsave_name = 'checkpoint_full_latest.mat';
        return;
    end
    step_token = regexp(checkpoint_name, '^checkpoint_step_(\d+)\.mat$', 'tokens', 'once');
    if ~isempty(step_token)
        fullsave_name = sprintf('checkpoint_full_step_%s.mat', step_token{1});
    end
end

function method_name = ternary_restart_fluence_method_local(flag_value)
% Map a scalar boolean Parseval flag onto the canonical method label.
    if logical(flag_value)
        method_name = 'parseval';
    else
        method_name = 'ifft_trapz';
    end
end
