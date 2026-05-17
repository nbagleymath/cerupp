classdef runtime_monitor_utils
%RUNTIME_MONITOR_UTILS Shared helpers for runtime and memory monitoring.
% Purpose:
% - Prepare and sample the runtime/memory-monitor surface used by the live driver.
% - Validate MEMMON controls, sample/check runtime memory state, and format
%   the monitoring output consumed by cerupp.m callers.
% Called mainly from cerupp.m during runtime monitoring and checkpoint decisions.

    methods (Static)
        function memmon_cfg = prepare_memmon_cfg(varargin)
%PREPARE_MEMMON_CFG Build the MEMMON config struct used by runtime sampling.
%   MEMMON_CFG = PREPARE_MEMMON_CFG(MEMMON_ABORT_GB, MEMMON_ABORT_ON_EXCEED)
%   MEMMON_CFG = PREPARE_MEMMON_CFG(MEMMON_ABORT_GB, MEMMON_ABORT_ON_EXCEED, PROJECTION_STRIDE_STEPS, EMIT_CHECKPOINT_INFO, ENABLE_BUDGET_WARNINGS, INFO_PHASE_TAG)
%   MEMMON_ABORT_GB must be a finite positive scalar or +Inf after setup
%   normalization. +Inf requests auto-detected available-memory budgeting.
%   MEMMON_ABORT_ON_EXCEED is logical-like; true requires a finite budget
%   to be available at setup. The returned struct carries the budget fields
%   memmon_abort_gb, memmon_abort_on_exceed, abort_budget_setup_gb, and
%   abort_budget_setup_source together with the runtime fields
%   projection_stride_steps, emit_checkpoint_info,
%   enable_budget_warnings, and info_phase_tag.

            if ~(nargin == 2 || nargin == 6)
                error('runtime_monitor_utils:PrepareMemmonCfgArity', ...
                    ['runtime_monitor_utils.prepare_memmon_cfg expects either 2 inputs ', ...
                     '(memmon_abort_gb, memmon_abort_on_exceed) or 6 inputs ', ...
                     '(memmon_abort_gb, memmon_abort_on_exceed, projection_stride_steps, ', ...
                     'emit_checkpoint_info, enable_budget_warnings, info_phase_tag); got %d inputs.'], nargin);
            end
            memmon_abort_gb = varargin{1};
            memmon_abort_on_exceed = varargin{2};
            if isempty(memmon_abort_on_exceed)
                error('runtime_monitor_utils:InvalidMemmonAbortOnExceedCfg', ...
                    'prepare_memmon_cfg requires explicit memmon_abort_on_exceed input.');
            end
            if ~isscalar(memmon_abort_gb) || ~isnumeric(memmon_abort_gb) || ~isreal(memmon_abort_gb) || ...
                    ~((isfinite(memmon_abort_gb) && (memmon_abort_gb > 0)) || (isinf(memmon_abort_gb) && (memmon_abort_gb > 0)))
                error('runtime_monitor_utils:InvalidMemmonAbortGbCfg', ...
                    ['prepare_memmon_cfg requires memmon_abort_gb to be a finite positive scalar ', ...
                     'or +Inf after setup normalization.']);
            end
            memmon_abort_gb = double(memmon_abort_gb);
            memmon_abort_on_exceed = struct_utils.normalize_bool_scalar( ...
                memmon_abort_on_exceed, 'memmon_abort_on_exceed', ...
                'runtime_monitor_utils:InvalidMemmonAbortOnExceedCfg');

            projection_stride_steps = 1;
            emit_checkpoint_info = true;
            enable_budget_warnings = true;
            info_phase_tag = 'propagation';
            if nargin == 6
                projection_stride_steps = varargin{3};
                emit_checkpoint_info = varargin{4};
                enable_budget_warnings = varargin{5};
                info_phase_tag = varargin{6};
            end
            projection_stride_steps = runtime_monitor_utils_validate_memmon_projection_stride_local( ...
                projection_stride_steps);
            emit_checkpoint_info = runtime_monitor_utils_validate_memmon_bool_scalar_local( ...
                emit_checkpoint_info, 'emit_checkpoint_info');
            enable_budget_warnings = runtime_monitor_utils_validate_memmon_bool_scalar_local( ...
                enable_budget_warnings, 'enable_budget_warnings');
            if isempty(info_phase_tag)
                error('runtime_monitor_utils:InvalidMemmonInfoPhaseTag', ...
                    'info_phase_tag must be provided when preparing MEMMON config.');
            end
            info_phase_tag = run_warn_state_utils.canonical_phase_name( ...
                info_phase_tag, 'runtime_monitor_utils:InvalidMemmonInfoPhaseTag');

            [abort_budget_setup_gb, abort_budget_setup_source] = resolve_mem_budget_gb_local( ...
                memmon_abort_gb, NaN);
            if memmon_abort_on_exceed && ~(isfinite(abort_budget_setup_gb) && (abort_budget_setup_gb > 0))
                error('runtime_monitor_utils:MemmonAbortBudgetUnavailable', ...
                    ['memmon_abort_on_exceed=true requires a finite memory budget at setup. ', ...
                     'Provide memmon_abort_gb explicitly or run on a platform where available-memory detection works.']);
            end
            memmon_cfg = struct( ...
                'memmon_abort_gb', memmon_abort_gb, ...
                'memmon_abort_on_exceed', memmon_abort_on_exceed, ...
                'abort_budget_setup_gb', double(abort_budget_setup_gb), ...
                'abort_budget_setup_source', abort_budget_setup_source, ...
                'projection_stride_steps', projection_stride_steps, ...
                'emit_checkpoint_info', emit_checkpoint_info, ...
                'enable_budget_warnings', enable_budget_warnings, ...
                'info_phase_tag', info_phase_tag);
        end

    end

    methods (Static)
        function varargout = memmon_checkpoint_fast(varargin)
%MEMMON_CHECKPOINT_FAST Sample memory usage and update MEMMON checkpoint state.
%   [MEMMON_LAST_GB, MEMMON_PEAK_GB, MEMMON_TIME_VEC, MEMMON_MEM_VEC, MEMMON_WARN_STATE] = ...
%   RUNTIME_MONITOR_UTILS.MEMMON_CHECKPOINT_FAST(TAG, CURR_Z_STEP, Z_CURR, PROP_CODE_START, MEMMON_TIME_VEC, MEMMON_MEM_VEC, NUM_ZSTEPS, MEMMON_LAST_GB, MEMMON_PEAK_GB, MEMMON_WARN_STATE, MEMMON_CFG)
%   MEMMON_CFG must be the validated struct built by PREPARE_MEMMON_CFG(...).
%   This entrypoint samples memory, updates MEMMON_WARN_STATE, and reports
%   projected memory via predicted-final usage when available, otherwise via
%   current memory as a fallback basis. MEMMON_CFG is expected to carry
%   projection_stride_steps, emit_checkpoint_info,
%   enable_budget_warnings, and info_phase_tag.
%   An optional sixth output returns a MEMMON_SAMPLE struct with fields
%   curr_time_s, curr_mem_gb, est_final_time_s, est_final_mem_gb,
%   projection_stride_steps, projection_sample_count, mem_budget_gb,
%   mem_budget_source, projected_eval_gb, and projected_basis.

            if nargin ~= 11
                error('runtime_monitor_utils:MemmonCheckpointFastArity', ...
                    ['runtime_monitor_utils.memmon_checkpoint_fast expects 11 inputs ', ...
                     '(including pre-normalized memmon_cfg); got %d inputs.'], nargin);
            end
            tag = varargin{1};
            curr_z_step = varargin{2};
            z_curr = varargin{3};
            prop_code_start = varargin{4};
            memmon_time_vec = varargin{5};
            memmon_mem_vec = varargin{6};
            num_zsteps = varargin{7};
            memmon_last_gb = varargin{8};
            memmon_peak_gb = varargin{9};
            memmon_warn_state = varargin{10};
            memmon_cfg = varargin{11};

            if ~isstruct(memmon_cfg)
                error('runtime_monitor_utils:InvalidMemmonCfg', ...
                    'memmon_checkpoint_fast requires a validated memmon_cfg struct.');
            end
            runtime_monitor_utils_require_memmon_last_peak_local(memmon_last_gb, memmon_peak_gb);
            memmon_warn_state = runtime_monitor_utils_require_memmon_warn_state_local(memmon_warn_state);
            required_fields = {'memmon_abort_gb', 'memmon_abort_on_exceed', ...
                'abort_budget_setup_gb', 'abort_budget_setup_source', ...
                'projection_stride_steps', 'emit_checkpoint_info', ...
                'enable_budget_warnings', 'info_phase_tag'};
            missing_fields = required_fields(~isfield(memmon_cfg, required_fields));
            if ~isempty(missing_fields)
                error('runtime_monitor_utils:InvalidMemmonCfg', ...
                    'memmon_cfg is missing field(s): %s', strjoin(missing_fields, ', '));
            end

            memmon_abort_gb = memmon_cfg.memmon_abort_gb;
            memmon_abort_on_exceed = memmon_cfg.memmon_abort_on_exceed;
            [mem_budget_gb, mem_budget_source] = runtime_monitor_utils_memmon_budget_snapshot_local(memmon_cfg);
            projection_stride_steps = memmon_cfg.projection_stride_steps;
            emit_checkpoint_info = memmon_cfg.emit_checkpoint_info;
            enable_budget_warnings = memmon_cfg.enable_budget_warnings;
            info_phase_tag = memmon_cfg.info_phase_tag;
            [memmon_sample, memmon_time_vec, memmon_mem_vec, memmon_warn_state.time_mem_warn_state] = ...
                runtime_monitor_utils_sample_resource_history_local( ...
                    prop_code_start, memmon_time_vec, memmon_mem_vec, ...
                    num_zsteps, projection_stride_steps, ...
                    memmon_warn_state.time_mem_warn_state);
            mem_gb = memmon_sample.curr_mem_gb;
            est_final_gb = memmon_sample.est_final_mem_gb;

            projected_eval_gb = est_final_gb;
            projected_basis = 'predicted_final';
            if ~isfinite(projected_eval_gb) && isfinite(mem_gb)
                projected_eval_gb = mem_gb;
                projected_basis = 'current';
            end

            dmem = NaN;
            if ~isnan(mem_gb)
                if isnan(memmon_last_gb)
                    dmem = NaN;
                else
                    dmem = mem_gb - memmon_last_gb;
                end
                memmon_last_gb = mem_gb;
                if isnan(memmon_peak_gb) || (mem_gb > memmon_peak_gb)
                    memmon_peak_gb = mem_gb;
                end
            end
            if isfinite(projected_eval_gb)
                proj_str = sprintf('%.3f', projected_eval_gb);
            else
                proj_str = 'NaN';
            end
            if isfinite(mem_budget_gb)
                budget_str = sprintf('%.3f (%s)', mem_budget_gb, mem_budget_source);
            else
                budget_str = sprintf('NaN (%s)', mem_budget_source);
            end
            if isfinite(memmon_peak_gb)
                peak_str = sprintf('%.3f', memmon_peak_gb);
            else
                peak_str = 'NaN';
            end
            memmon_sample.mem_budget_gb = mem_budget_gb;
            memmon_sample.mem_budget_source = mem_budget_source;
            memmon_sample.projected_eval_gb = projected_eval_gb;
            memmon_sample.projected_basis = projected_basis;
            if emit_checkpoint_info
                if isfinite(mem_gb)
                    mem_str = sprintf('%.3f', mem_gb);
                else
                    mem_str = 'NaN';
                end
                if isfinite(dmem)
                    dmem_str = sprintf('%.3f', dmem);
                else
                    dmem_str = 'NaN';
                end
                [memmon_warn_state, ~] = run_warn_state_utils.emit_bucket_info_with_phase( ...
                    memmon_warn_state, 'memmon', info_phase_tag, 'memmon_checkpoint', ...
                    ['MEMMON[%s] step=%d z=%.6g m | mem=%s GB | dmem=%s GB | ' ...
                     'peak=%s GB | proj=%s GB | budget=%s'], ...
                    tag, curr_z_step, z_curr, mem_str, dmem_str, peak_str, proj_str, budget_str);
            end

            if enable_budget_warnings && isfinite(mem_budget_gb) && isfinite(projected_eval_gb) && (projected_eval_gb > mem_budget_gb)
                msg = sprintf(['MEMMON soft warning (projected memory over budget): %s memory %.3f GB > budget %.3f GB ', ...
                               '(budget source: %s) at step %d (z=%.6g m). ', ...
                               '(RSS on Unix; MATLAB-reported memory on Windows). ', ...
                               'Continuing (non-fatal policy).'], ...
                               projected_basis, projected_eval_gb, mem_budget_gb, mem_budget_source, curr_z_step, z_curr);
                % Warn once per run for this condition; subsequent exceedances are still tracked
                % in memmon metrics but do not flood stdout/stderr.

                memmon_warn_state = run_warn_state_utils.emit_bucket_warn_once( ...
                    memmon_warn_state, 'memmon', ...
                    'memmon_projected_budget_exceeded', ...
                    'CerUPP:MemMon:ProjectedBudgetExceededSoft', ...
                    '%s', msg);
                if memmon_abort_on_exceed
                    % Keep identifier stable so existing catch/rethrow logic remains valid.

                    error('CerUPP:MemMon:AbortOnThreshold', ...
                        ['MEMMON abort_on_exceed=true and projected memory exceeded budget: %s'], msg);
                end
            elseif enable_budget_warnings && memmon_abort_on_exceed && ~isfinite(mem_budget_gb)
                error('CerUPP:MemMon:BudgetUnavailable', ...
                    ['MEMMON abort_on_exceed=true but available-memory budget is unavailable ', ...
                     '(override=inf and auto-detection failed).']);
            elseif enable_budget_warnings && isfinite(memmon_abort_gb) && isfinite(mem_gb) && (memmon_abort_gb > 0) && (mem_gb > memmon_abort_gb)
                % Retain one warning path for instantaneous overshoot against explicit override.

                msg = sprintf(['MEMMON soft warning (instantaneous memory over explicit budget): memory %.3f GB > %.3f GB at step %d (z=%.6g m). ', ...
                                   '(RSS on Unix; MATLAB-reported memory on Windows). ', ...
                                   'Continuing (non-fatal policy).'], ...
                                   mem_gb, memmon_abort_gb, curr_z_step, z_curr);
                memmon_warn_state = run_warn_state_utils.emit_bucket_warn_once( ...
                    memmon_warn_state, 'memmon', ...
                    'memmon_instant_budget_exceeded', ...
                    'CerUPP:MemMon:InstantBudgetExceededSoft', ...
                    '%s', msg);
            end

            outputs = {memmon_last_gb, memmon_peak_gb, memmon_time_vec, memmon_mem_vec, memmon_warn_state, memmon_sample};
            if nargout > numel(outputs)
                error('runtime_monitor_utils:MemmonCheckpointFastOutputArity', ...
                    'runtime_monitor_utils.memmon_checkpoint_fast supports at most %d outputs; got %d.', ...
                    numel(outputs), nargout);
            end
            varargout = outputs(1:nargout);
        end
    end
end

function runtime_monitor_utils_require_memmon_last_peak_local(memmon_last_gb, memmon_peak_gb)
% Validate explicit running-memory state for the shared MEMMON sampler.

    if ~(isnumeric(memmon_last_gb) && isscalar(memmon_last_gb) && isreal(memmon_last_gb))
        error('runtime_monitor_utils:InvalidMemmonLastGb', ...
            'memmon_last_gb must be an explicit real scalar (use NaN on first call).');
    end
    if ~(isnumeric(memmon_peak_gb) && isscalar(memmon_peak_gb) && isreal(memmon_peak_gb))
        error('runtime_monitor_utils:InvalidMemmonPeakGb', ...
            'memmon_peak_gb must be an explicit real scalar (use NaN on first call).');
    end
end

function memmon_warn_state = runtime_monitor_utils_require_memmon_warn_state_local(memmon_warn_state)
% Validate the explicit MEMMON warning-state shape used by all live entry paths.

    if ~(isstruct(memmon_warn_state) && isscalar(memmon_warn_state))
        error('runtime_monitor_utils:InvalidMemmonWarnState', ...
            ['memmon_warn_state must be a scalar struct carrying warned_keys ', ...
             'and time_mem_warn_state.']);
    end
    memmon_warn_state = struct_utils.ensure_warned_keys_map(memmon_warn_state);
    if ~isfield(memmon_warn_state, 'time_mem_warn_state') || ...
            ~isstruct(memmon_warn_state.time_mem_warn_state) || ...
            ~isscalar(memmon_warn_state.time_mem_warn_state)
        error('runtime_monitor_utils:InvalidMemmonWarnState', ...
            'memmon_warn_state.time_mem_warn_state must be a scalar struct.');
    end
    memmon_warn_state.time_mem_warn_state = ...
        runtime_monitor_utils_normalize_resource_warn_state_local( ...
            memmon_warn_state.time_mem_warn_state);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Runtime internals: Resource monitoring & limits
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [mem_budget_gb, source] = runtime_monitor_utils_memmon_budget_snapshot_local(memmon_cfg)
% Read the setup-owned MEMMON budget snapshot carried by memmon_cfg.

    mem_budget_gb = NaN;
    source = 'unavailable';
    if ~isstruct(memmon_cfg)
        return;
    end
    if isfield(memmon_cfg, 'abort_budget_setup_gb') && ~isempty(memmon_cfg.abort_budget_setup_gb)
        mem_budget_gb = double(memmon_cfg.abort_budget_setup_gb);
    end
    if isfield(memmon_cfg, 'abort_budget_setup_source') && ~isempty(memmon_cfg.abort_budget_setup_source)
        source = char(string(memmon_cfg.abort_budget_setup_source));
    end
end

function projection_stride_steps = runtime_monitor_utils_validate_memmon_projection_stride_local(projection_stride_steps)
% Validate the MEMMON projection downsampling stride as a positive integer scalar.

    projection_stride_steps = double(projection_stride_steps);
    if ~(isscalar(projection_stride_steps) && isreal(projection_stride_steps) && ...
            isfinite(projection_stride_steps) && (projection_stride_steps > 0) && ...
            (round(projection_stride_steps) == projection_stride_steps))
        error('runtime_monitor_utils:InvalidMemmonProjectionStrideSteps', ...
            'projection_stride_steps must be a finite positive integer scalar.');
    end
    projection_stride_steps = double(projection_stride_steps);
end

function flag_out = runtime_monitor_utils_validate_memmon_bool_scalar_local(flag_in, field_name)
% Validate MEMMON config booleans as strict scalar logical/{0,1} values.

    if nargin < 2 || isempty(field_name)
        field_name = 'memmon_cfg_flag';
    end
    flag_out = struct_utils.normalize_bool_scalar( ...
        flag_in, field_name, 'runtime_monitor_utils:InvalidMemmonBehaviorFlag');
end

function [mem_budget_gb, source] = resolve_mem_budget_gb_local(memmon_abort_gb, curr_mem_gb)
% Resolve the projected-memory budget and its source tag.
% SOURCE currently distinguishes override(memmon_abort_gb),
% cgroup_v2_remaining, cgroup_v2_limit_minus_process_mem,
% cgroup_v2_limit_only_unknown_remaining, cgroup_v1_remaining,
% cgroup_v1_limit_minus_process_mem, cgroup_v1_limit_only_unknown_remaining,
% proc_meminfo_available, and unavailable.
% Cgroup paths prefer (limit - current_usage_file); if the usage file is
% unavailable they fall back to (limit - curr_mem_gb) when curr_mem_gb is
% finite, otherwise they leave mem_budget_gb=NaN and report the matching
% *_limit_only_unknown_remaining source tag.
% Priority:
% 1) Explicit finite positive override via memmon_abort_gb.
% 2) Auto-detected available memory (job/cgroup/system).

    if isfinite(memmon_abort_gb) && (memmon_abort_gb > 0)
        mem_budget_gb = double(memmon_abort_gb);
        source = 'override(memmon_abort_gb)';
        return;
    end
    mem_budget_gb = NaN;
    source = 'unavailable';

    if isunix
        % cgroup v2 (common in modern schedulers/containers)

        [lim_b, ok_lim] = read_byte_scalar_local('/sys/fs/cgroup/memory.max');
        [cur_b, ok_cur] = read_byte_scalar_local('/sys/fs/cgroup/memory.current');
        if ok_lim && isfinite(lim_b) && (lim_b > 0)
            if ok_cur && isfinite(cur_b)
                mem_budget_gb = max(lim_b - cur_b, 0) / 1e9;
                source = 'cgroup_v2_remaining';
            elseif isfinite(curr_mem_gb)
                mem_budget_gb = max(lim_b - curr_mem_gb * 1e9, 0) / 1e9;
                source = 'cgroup_v2_limit_minus_process_mem';
            else
                mem_budget_gb = NaN;
                source = 'cgroup_v2_limit_only_unknown_remaining';
            end
            return;
        end

        % cgroup v1 fallback
        [lim_b, ok_lim] = read_byte_scalar_local('/sys/fs/cgroup/memory/memory.limit_in_bytes');
        [cur_b, ok_cur] = read_byte_scalar_local('/sys/fs/cgroup/memory/memory.usage_in_bytes');
        if ok_lim && isfinite(lim_b) && (lim_b > 0)
            if ok_cur && isfinite(cur_b)
                mem_budget_gb = max(lim_b - cur_b, 0) / 1e9;
                source = 'cgroup_v1_remaining';
            elseif isfinite(curr_mem_gb)
                mem_budget_gb = max(lim_b - curr_mem_gb * 1e9, 0) / 1e9;
                source = 'cgroup_v1_limit_minus_process_mem';
            else
                mem_budget_gb = NaN;
                source = 'cgroup_v1_limit_only_unknown_remaining';
            end
            return;
        end

        % System-wide fallback
        [mem_avail_b, ok_mem] = read_memavailable_bytes_local();
        if ok_mem && isfinite(mem_avail_b) && (mem_avail_b >= 0)
            mem_budget_gb = mem_avail_b / 1e9;
            source = 'proc_meminfo_available';
            return;
        end
    end
end

function [val_b, ok] = read_byte_scalar_local(path_in)
% Read scalar byte values from cgroup-like files.
% Literal 'max' and huge sentinel-like numeric values are treated as
% unbounded / Inf; malformed, empty, or negative tokens fail with ok=false.

    val_b = NaN;
    ok = false;
    fid = fopen(path_in, 'r');
    if fid < 0
        return;
    end
    fid_cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    line = fgetl(fid);
    if ~ischar(line)
        return;
    end
    token = strtrim(line);
    if isempty(token)
        return;
    end
    if strcmpi(token, 'max')
        val_b = Inf;
        ok = true;
        return;
    end
    val_b = str2double(token);
    if ~isfinite(val_b) || (val_b < 0)
        val_b = NaN;
        return;
    end
    % Many systems use huge sentinel values for "effectively unbounded".

    if val_b > 1e15
        val_b = Inf;
    end
    ok = true;
end

function [mem_avail_b, ok] = read_memavailable_bytes_local()
% Parse MemAvailable from /proc/meminfo and return bytes.
% The source field is reported in kB, so this helper converts to bytes.
% Open/parse/missing-line failures are soft and return mem_avail_b=NaN with
% ok=false instead of throwing.

    mem_avail_b = NaN;
    ok = false;
    fid = fopen('/proc/meminfo', 'r');
    if fid < 0
        return;
    end
    fid_cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    while true
        line = fgetl(fid);
        if ~ischar(line)
            break;
        end
        tok = regexp(line, '^MemAvailable:\s*([0-9]+)\s*kB', 'tokens', 'once');
        if ~isempty(tok)
            mem_avail_b = str2double(tok{1}) * 1024;
            ok = isfinite(mem_avail_b) && (mem_avail_b >= 0);
            return;
        end
    end
end

function [resource_sample, time_usage_vec, memory_usage_vec, warn_state] = ...
        runtime_monitor_utils_sample_resource_history_local(prop_code_start, time_usage_vec, memory_usage_vec, ...
        num_zsteps, projection_stride_steps, warn_state)
% Sample current runtime resources, append history, and project final usage.

    curr_time = toc(prop_code_start);
    warn_state = runtime_monitor_utils_require_resource_warn_state_local(warn_state);
    [curr_mem, warn_state] = runtime_monitor_utils_sample_current_memory_gb_local(warn_state);
    [time_usage_vec, memory_usage_vec] = runtime_monitor_utils_append_resource_history_local( ...
        time_usage_vec, memory_usage_vec, curr_time, curr_mem);
    [est_final_time, est_final_mem, num_projected_samples] = ...
        runtime_monitor_utils_project_resource_history_local( ...
            curr_time, time_usage_vec, memory_usage_vec, ...
            num_zsteps, projection_stride_steps);
    resource_sample = struct( ...
        'curr_time_s', double(curr_time), ...
        'curr_mem_gb', double(curr_mem), ...
        'est_final_time_s', double(est_final_time), ...
        'est_final_mem_gb', double(est_final_mem), ...
        'projection_stride_steps', double(projection_stride_steps), ...
        'projection_sample_count', double(num_projected_samples));
end

function warn_state = runtime_monitor_utils_require_resource_warn_state_local(warn_state)
% Validate the resource warning-state struct used by the private sampler.
% The public MEMMON entry path already normalizes the warned-key map shape.

    if ~isstruct(warn_state) || ~isscalar(warn_state)
        error('runtime_monitor_utils:InvalidResourceWarnState', ...
            'warn_state input is required and must be a scalar struct.');
    end
    warn_state = struct_utils.ensure_warned_keys_map(warn_state);
end

function warn_state = runtime_monitor_utils_normalize_resource_warn_state_local(warn_state)
% Normalize the MEMMON resource warning-state map at the public ingress.

    warn_state = struct_utils.ensure_warned_keys_map(warn_state);
end

function [curr_mem, warn_state] = runtime_monitor_utils_sample_current_memory_gb_local(warn_state)
% Query current process memory with the available cross-platform fallbacks.

    curr_mem = NaN;
    if ispc
        if runtime_monitor_utils_warn_key_seen_local(warn_state, 'windows_mem_failed')
            return;
        end
        try
            m = memory;
            curr_mem = m.MemUsedMATLAB / 1e9;
        catch me
            warn_state = runtime_monitor_utils_emit_resource_warn_latched_local( ...
                warn_state, 'windows_mem_failed', 'CerUPP:Resources:WindowsMemoryFailed', ...
                'memory() failed on Windows; memory tracking will be NaN. Details: %s', me.message);
        end
        return;
    end
    if isunix
        if ~runtime_monitor_utils_warn_key_seen_local(warn_state, 'ps_mem_failed')
            try
                pid = feature('getpid');
                [status, out] = system(sprintf('ps -o rss= -p %d', pid));
                if status == 0
                    kb_val = str2double(strtrim(out));
                    if ~isnan(kb_val)
                        curr_mem = (kb_val * 1024) / 1e9;
                    else
                        warn_state = runtime_monitor_utils_emit_resource_warn_latched_local( ...
                            warn_state, 'ps_mem_failed', 'CerUPP:Resources:PsParseFailed', ...
                            'ps RSS output could not be parsed (out="%s"). Memory tracking will be NaN.', strtrim(out));
                    end
                else
                    warn_state = runtime_monitor_utils_emit_resource_warn_latched_local( ...
                        warn_state, 'ps_mem_failed', 'CerUPP:Resources:PsCommandFailed', ...
                        'ps command failed (status=%d, out="%s"). Memory tracking will be NaN.', status, strtrim(out));
                end
            catch me
                warn_state = runtime_monitor_utils_emit_resource_warn_latched_local( ...
                    warn_state, 'ps_mem_failed', 'CerUPP:Resources:PsQueryFailed', ...
                    'ps-based memory query failed; memory tracking will be NaN. Details: %s', me.message);
            end
        end
        if isnan(curr_mem)
            [curr_mem, warn_state] = runtime_monitor_utils_sample_status_memory_gb_local(warn_state);
        end
    end
end

function [curr_mem, warn_state] = runtime_monitor_utils_sample_status_memory_gb_local(warn_state)
% Fallback to MATLAB's internal memory status query when available.

    curr_mem = NaN;
    if runtime_monitor_utils_warn_key_seen_local(warn_state, 'status_mem_failed')
        return;
    end
    try
        s = memory('status');
        if isfield(s, 'MemUsedMATLAB')
            curr_mem = s.MemUsedMATLAB / 1e9;
        end
    catch me
        warn_state = runtime_monitor_utils_emit_resource_warn_latched_local( ...
            warn_state, 'status_mem_failed', 'CerUPP:Resources:StatusMemoryFailed', ...
            'memory(''status'') fallback failed; memory tracking will remain NaN. Details: %s', me.message);
    end
end

function tf = runtime_monitor_utils_warn_key_seen_local(warn_state, warn_key)
% Query one resource-failure latch in the shared warned_keys set.

    warn_state = struct_utils.ensure_warned_keys_map(warn_state);
    tf = struct_utils.warned_key_seen(warn_state, warn_key);
end

function warn_state = runtime_monitor_utils_emit_resource_warn_latched_local( ...
        warn_state, warn_key, canon_id, msg_fmt, varargin)
% Emit one latched resource warning through the owned MEMMON warning ledger.

    [warn_state, ~] = run_warn_state_utils.emit_bucket_warn_once( ...
        warn_state, 'memmon', ...
        warn_key, canon_id, msg_fmt, varargin{:});
end

function [time_usage_vec, memory_usage_vec] = runtime_monitor_utils_append_resource_history_local( ...
        time_usage_vec, memory_usage_vec, curr_time, curr_mem)
% Append the latest resource samples onto the caller-owned history vectors.

    time_usage_vec = runtime_monitor_utils_require_numeric_history_vector_local( ...
        time_usage_vec, 'time_usage_vec');
    memory_usage_vec = runtime_monitor_utils_require_numeric_history_vector_local( ...
        memory_usage_vec, 'memory_usage_vec');
    time_usage_vec(end+1) = curr_time;
    memory_usage_vec(end+1) = curr_mem;
end

function vec = runtime_monitor_utils_require_numeric_history_vector_local(vec, vec_name)
% Enforce the one-dimensional MEMMON history contract before appending.

    if nargin < 2 || isempty(vec_name)
        vec_name = 'history_vec';
    end
    if isempty(vec)
        vec = [];
        return;
    end
    if ~(isnumeric(vec) && isreal(vec) && isvector(vec))
        error('runtime_monitor_utils:InvalidHistoryVector', ...
            '%s must be a real numeric vector or [].', vec_name);
    end
end

function [est_final_time, est_final_mem, num_projected_samples] = ...
        runtime_monitor_utils_project_resource_history_local( ...
        curr_time, time_usage_vec, memory_usage_vec, num_zsteps, projection_stride_steps)
% Project final runtime and memory usage from the current history vectors.

    projection_stride_steps = double(projection_stride_steps);
    num_projected_samples = ceil(num_zsteps / projection_stride_steps);
    if numel(time_usage_vec) >= num_projected_samples
        est_final_time = curr_time;
        if ~isempty(memory_usage_vec)
            est_final_mem = memory_usage_vec(end);
        else
            est_final_mem = NaN;
        end
        return;
    end
    if numel(time_usage_vec) > 1
        avg_time_inc = mean(diff(time_usage_vec));
        est_final_time = curr_time + avg_time_inc * (num_projected_samples - numel(time_usage_vec));
    else
        est_final_time = curr_time;
    end
    valid_mem_idx = find(~isnan(memory_usage_vec));
    if numel(valid_mem_idx) >= 2
        i1 = valid_mem_idx(end - 1);
        i2 = valid_mem_idx(end);
        gap = max(i2 - i1, 1);
        mem_inc_per_checkpoint = (memory_usage_vec(i2) - memory_usage_vec(i1)) / gap;
        remaining_projected_samples = max(num_projected_samples - i2, 0);
        est_final_mem = memory_usage_vec(i2) + mem_inc_per_checkpoint * remaining_projected_samples;
    elseif numel(valid_mem_idx) == 1
        est_final_mem = memory_usage_vec(valid_mem_idx(1));
    else
        est_final_mem = NaN;
    end
end
