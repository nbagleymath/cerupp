classdef warning_utils
%WARNING_UTILS Emit CerUPP warnings/info lines and build retained summaries.
% Purpose:
% - Keep warning and informational emission in one place so setup,
%   propagation, and end-of-run summaries share one voice.
% Public helpers emit warnings, warn-once messages, and transient info
% lines. Hidden helpers also own shared warning-ID normalization/default-ID
% helpers and the retained-info / end-of-run summary machinery used across
% the warning-ledger stack.
% Called across setup, propagation, checkpoint, and postprocess warning paths.

    methods (Static)
        function cerupp_warn(canon_id, varargin)
%CERUPP_WARN Emit one CerUPP warning.
%   WARNING_UTILS.CERUPP_WARN(CANON_ID, FMT, ...)
%   Validates CANON_ID, formats the message, and calls MATLAB warning().
%   If that warning ID is disabled, this helper returns without emitting.

            warning_utils_warn_core_local(false, canon_id, varargin{:});
        end

        function cerupp_info(varargin)
%CERUPP_INFO Emit transient informational runtime output.
%   CERUPP_INFO(PHASE_TAG, INFO_KEY, FMT, ...)
%   Prints informational stdout output prefixed with the phase tag and a
%   normalized info_key token. INFO_KEY is lowercased and must match
%   [a-z][a-z0-9_]* after normalization. Embedded newline characters in the
%   formatted payload are preserved. Use the retained-info path only when
%   the message must also be stored in a bounded state ledger.

            if numel(varargin) < 3
                error('CerUPP:WarningUtils:MissingInfoMessage', ...
                    'cerupp_info requires phase_tag, info_key, and a message format.');
            end
            phase_tag = varargin{1};
            info_key = varargin{2};
            msg_fmt = varargin{3};
            if isstring(msg_fmt) && isscalar(msg_fmt), msg_fmt = char(msg_fmt); end
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidEmitWarningPhaseTag');
            info_key = warning_utils_normalize_info_key_local(info_key);
            if ~ischar(msg_fmt)
                error('CerUPP:WarningUtils:InvalidInfoMessage', 'msg_fmt must be char or scalar string.');
            end

            msg = sprintf(msg_fmt, varargin{4:end});
            warning_utils_emit_info_line_local(phase_tag, info_key, msg);
        end

        function [warn_state, emitted] = cerupp_warn_once(warn_state, warn_key, canon_id, msg_fmt, varargin)
%CERUPP_WARN_ONCE Emit one warning and latch its once-key on first emission.
%   [WARN_STATE, EMITTED] = WARNING_UTILS.CERUPP_WARN_ONCE(WARN_STATE, WARN_KEY, CANON_ID, FMT, ...)
%   WARN_STATE must be a scalar struct; the updated warned_keys ledger is
%   returned. WARN_KEY is the required nonempty caller-owned once key.
%   CANON_ID is validated before emission. Disabled warning IDs return
%   EMITTED=false and leave WARN_KEY unlatched so a later re-enabled first
%   occurrence can still emit.

            [warn_state, emitted] = warning_utils_warn_once_core_local( ...
                false, ...
                warn_state, warn_key, canon_id, msg_fmt, varargin{:});
        end

    end

    methods (Static, Hidden)
        function end_ctx = resolve_end_memmon_state(end_ctx)
%RESOLVE_END_MEMMON_STATE Resolve late end-of-run MEMMON sampling before summary emission.
%   END_CTX = RESOLVE_END_MEMMON_STATE(END_CTX)
%   END_CTX is the end-of-run MEMMON context with required fields:
%     warn_states, do_memmon_base, num_zsteps, z_end, prop_code_start,
%     memmon_abort_gb, memmon_abort_on_exceed, memmon_time_vec,
%     memmon_mem_vec, memmon_last_gb, memmon_peak_gb, and memmon_warn_state.
%   Optional fields are memmon_end_sample_needed,
%     memmon_projection_stride_steps, terminal_memmon_last_gb, and
%     terminal_memmon_peak_gb. The returned struct carries the updated
%     warning bundle plus the resolved MEMMON vectors/scalars.

            end_ctx = resolve_end_memmon_state_core_local(end_ctx);
        end

        % Shared internal API used by the driver, plotting, and warning ledgers.
        function end_ctx = emit_run_end_warnings(end_ctx)
%EMIT_RUN_END_WARNINGS Emit end-of-run warning summaries.
%   END_CTX = EMIT_RUN_END_WARNINGS(END_CTX)
%   END_CTX is the end-of-run summary context struct with required fields:
%     source_tag and warn_states.
%   Optional field reset_after_emit defaults to false. The returned struct
%   carries the consolidated warning ledgers after summary emission.

            end_ctx = emit_run_end_warning_summaries_core_local(end_ctx);
        end

        function warn_states = emit_resetting_run_end_warnings(source_tag, warn_states)
%EMIT_RESETTING_RUN_END_WARNINGS Emit and reset one end-of-run warning pass.

            end_ctx = warning_utils.emit_run_end_warnings(struct( ...
                'source_tag', source_tag, ...
                'warn_states', warn_states, ...
                'reset_after_emit', true));
            warn_states = end_ctx.warn_states;
        end

        function [state, msg_txt] = cerupp_info_with_state(state, phase_tag, info_key, msg_fmt, varargin)
%CERUPP_INFO_WITH_STATE Emit informational runtime output and retain it in a bounded state ledger.
%   [STATE, MSG_TXT] = CERUPP_INFO_WITH_STATE(STATE, PHASE_TAG, INFO_KEY, FMT, ...)
%   appends the formatted informational event to STATE.info_event and also
%   prints the informational stdout line.
%   Printed output preserves embedded newlines, while the retained state
%   copy is flattened to single-line text before storage.

            if nargin < 4
                error('CerUPP:WarningUtils:MissingInfoMessage', ...
                    'cerupp_info_with_state requires state, phase_tag, info_key, and a message format.');
            end
            if ~(isstruct(state) && isscalar(state))
                error('CerUPP:WarningUtils:InvalidInfoState', ...
                    'state must be a scalar struct for cerupp_info_with_state; got %s.', class(state));
            end
            if isstring(msg_fmt) && isscalar(msg_fmt), msg_fmt = char(msg_fmt); end
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidEmitWarningPhaseTag');
            info_key = warning_utils_normalize_info_key_local(info_key);
            if ~ischar(msg_fmt)
                error('CerUPP:WarningUtils:InvalidInfoMessage', 'msg_fmt must be char or scalar string.');
            end
            msg_txt = sprintf(msg_fmt, varargin{:});
            state = warning_utils_append_info_event_local(state, phase_tag, info_key, msg_txt);
            warning_utils_emit_info_line_local(phase_tag, info_key, msg_txt);
        end

        function canon_id = normalize_warning_id(canon_id)
%NORMALIZE_WARNING_ID Normalize warning IDs without a second hard contract layer.

            if isstring(canon_id) && isscalar(canon_id)
                canon_id = char(canon_id);
            end
            canon_id = strtrim(char(canon_id));
        end

        function [msg_txt, format_failed, emitted] = cerupp_warn_with_message(canon_id, msg_fmt, varargin)
%CERUPP_WARN_WITH_MESSAGE Emit one warning and return the formatted message text.
%   [MSG_TXT, FORMAT_FAILED, EMITTED] = CERUPP_WARN_WITH_MESSAGE(...)
%   Disabled warning IDs return EMITTED=false and MSG_TXT=''. If sprintf
%   formatting fails, MSG_TXT is the explicit fallback warning text that
%   was retained/emitted, FORMAT_FAILED=true, and disabled-warning policy
%   still controls whether any warning was actually emitted.

            [msg_txt, format_failed, emitted] = warning_utils_warn_core_local( ...
                true, ...
                canon_id, msg_fmt, varargin{:});
        end

        function [warn_state, emitted, msg_txt, format_failed] = cerupp_warn_once_with_message( ...
                warn_state, warn_key, canon_id, msg_fmt, varargin)
%CERUPP_WARN_ONCE_WITH_MESSAGE Emit one deduplicated warning and return the formatted message text.
%   WARN_KEY must be a nonempty caller-owned once-latch key. Disabled
%   warning IDs return EMITTED=false and MSG_TXT='' without latching
%   WARN_KEY, so a later re-enabled first occurrence can still emit. If sprintf formatting fails,
%   MSG_TXT is the explicit fallback warning text that was retained/emitted
%   and FORMAT_FAILED=true while the normal disabled-warning policy still
%   governs whether any warning was emitted.

            [warn_state, emitted, msg_txt, format_failed] = ...
                warning_utils_warn_once_core_local( ...
                    true, warn_state, warn_key, canon_id, msg_fmt, varargin{:});
        end

    end
end

function warning_utils_emit_info_line_local(phase_tag, info_key, msg)
% Emit one canonical informational stdout line.

    msg_emitted = sprintf('[%s:%s] %s', phase_tag, info_key, msg);
    if ~isempty(msg_emitted) && (msg_emitted(end) == newline)
        fprintf('%s', msg_emitted);
    else
        fprintf('%s\n', msg_emitted);
    end
end

function [msg_txt, format_failed, emitted] = warning_utils_warn_core_local( ...
        return_message_text, canon_id, msg_fmt, varargin)
% Emit one warning after validating the ID and, when requested, pre-rendering the message text.

    if nargin < 2 || isempty(canon_id)
        error('CerUPP:WarningUtils:MissingCanonicalWarningID', 'canon_id is required.');
    end
    if nargin < 3
        error('CerUPP:WarningUtils:MissingWarningMessage', 'warning message format is required.');
    end

    if isstring(canon_id) && isscalar(canon_id), canon_id = char(canon_id); end
    canon_id = warning_utils.normalize_warning_id(canon_id);
    emitted = false;
    msg_txt = '';
    format_failed = false;
    if warning_utils_warning_disabled_local(canon_id)
        return;
    end
    if return_message_text
        [msg_txt, format_failed] = warning_utils_render_warning_message_local(msg_fmt, varargin{:});
        warning(canon_id, '%s', msg_txt);
    else
        warning(canon_id, msg_fmt, varargin{:});
    end
    emitted = true;
end

function [warn_state, emitted, msg_txt, format_failed] = warning_utils_warn_once_core_local( ...
        return_message_text, warn_state, warn_key, canon_id, msg_fmt, varargin)
% Emit one deduplicated warning after checking the caller-owned once key.

    got_class = '<missing>';
    if nargin >= 2
        got_class = class(warn_state);
    end
    if nargin < 2 || ~isstruct(warn_state) || ~isscalar(warn_state)
        error('CerUPP:WarningUtils:InvalidWarnState', ...
            ['warn_state must be a scalar struct carrying caller-owned warning state; ' ...
             'got %s.'], ...
            got_class);
    end
    warn_state = struct_utils.ensure_warned_keys_map(warn_state);
    emitted = false;
    msg_txt = '';
    format_failed = false;

    if isstring(warn_key) && isscalar(warn_key), warn_key = char(warn_key); end
    if isstring(canon_id) && isscalar(canon_id), canon_id = char(canon_id); end
    canon_id = warning_utils.normalize_warning_id(canon_id);
    if ~ischar(warn_key) || isempty(strtrim(warn_key))
        error('CerUPP:WarningUtils:MissingWarnKey', ...
            ['warn_key must be a nonempty caller-owned once-key; ' ...
             'empty-key fallback to canon_id is no longer supported.']);
    end
    warn_key = strtrim(warn_key);

    if struct_utils.warned_key_seen(warn_state, warn_key)
        return;
    end
    if warning_utils_warning_disabled_local(canon_id)
        return;
    end

    if return_message_text
        [msg_txt, format_failed] = warning_utils_render_warning_message_local(msg_fmt, varargin{:});
        warning(canon_id, '%s', msg_txt);
    else
        warning(canon_id, msg_fmt, varargin{:});
    end
    warn_state = struct_utils.add_warned_key(warn_state, warn_key);
    emitted = true;
end

function [msg_txt, format_failed] = warning_utils_render_warning_message_local(msg_fmt, varargin)
% Format warning text once and make format failures explicit to callers.
% If sprintf formatting fails, return an explicit retained/emitted fallback
% string of the form [format_failed:<id>] msg_fmt, mark FORMAT_FAILED, and
% emit a separate internal warning so producer-side format bugs remain
% visible during development.

    if isstring(msg_fmt) && isscalar(msg_fmt)
        msg_fmt = char(msg_fmt);
    end
    if ~ischar(msg_fmt)
        error('CerUPP:WarningUtils:InvalidWarningMessage', 'msg_fmt must be char or scalar string.');
    end
    format_failed = false;
    try
        msg_txt = sprintf(msg_fmt, varargin{:});
    catch me
        msg_txt = warning_utils_format_failure_message_local(msg_fmt, me);
        format_failed = true;
        warning('CerUPP:WarningUtils:FormatFailure', '%s', msg_txt);
    end
end

function tf = warning_utils_warning_disabled_local(canon_id)
% Respect MATLAB warning-state queries on the canonical warning ID only.

    tf = false;
    s_state = warning('query', canon_id);
    if isstruct(s_state) && isfield(s_state, 'state') && strcmpi(s_state.state, 'off')
        tf = true;
    end
end

function token_out = warning_utils_normalize_warning_id_token_local(token_in, token_label)
% Validate internal warning-ID tokens used by the shared owner-first defaults.

    if nargin < 2 || isempty(token_label)
        token_label = 'warning ID token';
    end
    if isstring(token_in) && isscalar(token_in)
        token_in = char(token_in);
    end
    if ~ischar(token_in)
        error('CerUPP:WarningUtils:InvalidWarningIDToken', ...
            '%s must be a char vector or scalar string.', token_label);
    end
    token_out = strtrim(token_in);
    if isempty(token_out) || isempty(regexp(token_out, '^[A-Za-z][A-Za-z0-9]*$', 'once'))
        error('CerUPP:WarningUtils:InvalidWarningIDToken', ...
            '%s must match [A-Za-z][A-Za-z0-9]*; got "%s".', token_label, token_out);
    end
end

function info_key = warning_utils_normalize_info_key_local(info_key)
% Normalize public informational message keys onto one token contract.

    if isstring(info_key) && isscalar(info_key)
        info_key = char(info_key);
    end
    if ~ischar(info_key)
        error('CerUPP:WarningUtils:InvalidInfoKey', ...
            'info_key must be a char vector or scalar string.');
    end
    info_key = strtrim(lower(info_key));
    if isempty(info_key) || isempty(regexp(info_key, '^[a-z][a-z0-9_]*$', 'once'))
        error('CerUPP:WarningUtils:InvalidInfoKey', ...
            'info_key must match [a-z][a-z0-9_]*; got "%s".', info_key);
    end
end

function msg_txt = warning_utils_format_failure_message_local(msg_fmt, me)
% Build an explicit emitted/retained warning string when sprintf formatting fails.

    format_id = 'unknown_format_failure';
    if isa(me, 'MException') && ~isempty(me.identifier)
        format_id = me.identifier;
    end
    msg_txt = sprintf('[format_failed:%s] %s', format_id, msg_fmt);
end

function state = warning_utils_append_info_event_local(state, phase_tag, info_key, msg_txt)
% Append one bounded informational event into STATE.info_event.

    info_state = warning_utils_normalize_info_event_state_local( ...
        struct_utils.opt_struct_field(state, 'info_event', struct()));
    event = warning_utils_empty_info_event_local();
    event.phase_tag = char(string(phase_tag));
    event.info_key = char(string(info_key));
    event.message = warning_utils_flatten_info_message_local(msg_txt);
    info_state.events(end+1, 1) = event;
    if numel(info_state.events) > info_state.history_limit
        info_state.events = info_state.events((end - info_state.history_limit + 1):end);
    end
    state.info_event = info_state;
end

function info_state = warning_utils_normalize_info_event_state_local(info_state)
% Normalize the bounded informational-event ledger carried on owner state structs.

    default_state = warning_utils_empty_info_event_state_local();
    if nargin < 1 || isempty(info_state)
        info_state = default_state;
        return;
    end
    if ~(isstruct(info_state) && isscalar(info_state))
        error('CerUPP:WarningUtils:InvalidInfoEventState', ...
            'info_event state must be a scalar struct when provided.');
    end
    history_limit = default_state.history_limit;
    if isfield(info_state, 'history_limit') && isnumeric(info_state.history_limit) && ...
            isscalar(info_state.history_limit) && isfinite(info_state.history_limit) && ...
            (info_state.history_limit >= 1)
        history_limit = floor(double(info_state.history_limit));
    end
    events_in = repmat(warning_utils_empty_info_event_local(), 0, 1);
    if isfield(info_state, 'events')
        events_in = info_state.events;
    end
    events = repmat(warning_utils_empty_info_event_local(), 0, 1);
    if isstruct(events_in)
        for ii = 1:numel(events_in)
            event_in = events_in(ii);
            event = warning_utils_empty_info_event_local();
            event.phase_tag = run_warn_state_utils.canonical_phase_name( ...
                struct_utils.opt_struct_field(event_in, 'phase_tag', 'unknown'));
            event.info_key = warning_utils_normalize_info_key_local( ...
                struct_utils.opt_struct_field(event_in, 'info_key', 'info_event'));
            event.message = warning_utils_flatten_info_message_local( ...
                struct_utils.opt_struct_field(event_in, 'message', ''));
            events(end+1, 1) = event; %#ok<AGROW>
        end
    end
    if numel(events) > history_limit
        events = events((end - history_limit + 1):end);
    end
    info_state = struct('history_limit', history_limit, 'events', events);
end

function info_state = warning_utils_empty_info_event_state_local()
% Fixed schema for bounded informational-event ledgers.

    info_state = struct( ...
        'history_limit', 8, ...
        'events', repmat(warning_utils_empty_info_event_local(), 0, 1));
end

function event = warning_utils_empty_info_event_local()
% Fixed schema for one retained informational event.

    event = struct( ...
        'phase_tag', '', ...
        'info_key', '', ...
        'message', '');
end

function msg_txt = warning_utils_flatten_info_message_local(msg_txt)
% Flatten embedded line breaks before retaining informational event text in state.

    if isstring(msg_txt) && isscalar(msg_txt)
        msg_txt = char(msg_txt);
    end
    if ~ischar(msg_txt)
        msg_txt = '';
        return;
    end
    msg_txt = strrep(msg_txt, sprintf('\n'), ' ');
    msg_txt = strrep(msg_txt, sprintf('\r'), ' ');
end

function end_ctx = resolve_end_memmon_state_core_local(end_ctx)
% Canonical struct-owned implementation for end-of-run MEMMON resolution.

    if isempty(end_ctx) || ~isstruct(end_ctx) || ~isscalar(end_ctx)
        error('CerUPP:WarningUtils:InvalidEndContext', ...
            'end_ctx must be a struct for the canonical end-of-run MEMMON path.');
    end
    warn_states_in = struct_utils.req_struct_field(end_ctx, 'warn_states', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    do_memmon_base = struct_utils.req_struct_field(end_ctx, 'do_memmon_base', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    num_zsteps = struct_utils.req_struct_field(end_ctx, 'num_zsteps', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    z_end = struct_utils.req_struct_field(end_ctx, 'z_end', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    prop_code_start = struct_utils.req_struct_field(end_ctx, 'prop_code_start', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    memmon_abort_gb = struct_utils.req_struct_field(end_ctx, 'memmon_abort_gb', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    memmon_abort_on_exceed = struct_utils.req_struct_field(end_ctx, 'memmon_abort_on_exceed', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    memmon_time_vec = struct_utils.req_struct_field(end_ctx, 'memmon_time_vec', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    memmon_mem_vec = struct_utils.req_struct_field(end_ctx, 'memmon_mem_vec', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    memmon_last_gb = struct_utils.req_struct_field(end_ctx, 'memmon_last_gb', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    memmon_peak_gb = struct_utils.req_struct_field(end_ctx, 'memmon_peak_gb', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    memmon_warn_state_fallback = struct_utils.opt_struct_field(end_ctx, ...
        'memmon_warn_state', struct());
    memmon_end_sample_needed = struct_utils.opt_struct_field(end_ctx, ...
        'memmon_end_sample_needed', true);
    memmon_projection_stride_steps = struct_utils.opt_struct_field(end_ctx, ...
        'memmon_projection_stride_steps', 1);
    terminal_memmon_last_gb = struct_utils.opt_struct_field(end_ctx, ...
        'terminal_memmon_last_gb', NaN);
    terminal_memmon_peak_gb = struct_utils.opt_struct_field(end_ctx, ...
        'terminal_memmon_peak_gb', NaN);

    if ~(isscalar(do_memmon_base) && (islogical(do_memmon_base) || isnumeric(do_memmon_base)))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.do_memmon_base must be a scalar logical/numeric flag.');
    end
    if ~(isnumeric(memmon_last_gb) && isscalar(memmon_last_gb) && isreal(memmon_last_gb))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.memmon_last_gb must be an explicit real scalar.');
    end
    if ~(isnumeric(memmon_peak_gb) && isscalar(memmon_peak_gb) && isreal(memmon_peak_gb))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.memmon_peak_gb must be an explicit real scalar.');
    end
    if ~(isstruct(memmon_warn_state_fallback) && isscalar(memmon_warn_state_fallback))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.memmon_warn_state must be a scalar struct when provided.');
    end
    do_memmon_base = logical(do_memmon_base);
    if ~(isscalar(memmon_end_sample_needed) && (islogical(memmon_end_sample_needed) || isnumeric(memmon_end_sample_needed)))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.memmon_end_sample_needed must be a scalar logical/numeric flag when provided.');
    end
    memmon_end_sample_needed = logical(memmon_end_sample_needed);
    if ~(isnumeric(memmon_projection_stride_steps) && isscalar(memmon_projection_stride_steps) && ...
            isreal(memmon_projection_stride_steps) && isfinite(memmon_projection_stride_steps) && ...
            (memmon_projection_stride_steps > 0))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.memmon_projection_stride_steps must be a finite real scalar > 0 when provided.');
    end
    memmon_projection_stride_steps = max(1, round(double(memmon_projection_stride_steps)));
    if ~(isnumeric(terminal_memmon_last_gb) && isscalar(terminal_memmon_last_gb) && isreal(terminal_memmon_last_gb))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.terminal_memmon_last_gb must be a real scalar when provided.');
    end
    if ~(isnumeric(terminal_memmon_peak_gb) && isscalar(terminal_memmon_peak_gb) && isreal(terminal_memmon_peak_gb))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.terminal_memmon_peak_gb must be a real scalar when provided.');
    end

    warn_states_in = run_warn_state_utils.require_warning_ledger_bundle( ...
        warn_states_in, struct(), memmon_warn_state_fallback, ...
        'CerUPP:WarningUtils:MissingWarnBundle');
    run_warn_state = warn_states_in.run;
    memmon_warn_state = warn_states_in.memmon;

    if do_memmon_base
        if memmon_end_sample_needed
            try
                memmon_cfg = runtime_monitor_utils.prepare_memmon_cfg( ...
                    memmon_abort_gb, memmon_abort_on_exceed, ...
                    memmon_projection_stride_steps, true, true, 'end');
                [memmon_last_gb, memmon_peak_gb, memmon_time_vec, memmon_mem_vec, memmon_warn_state] = ...
                    runtime_monitor_utils.memmon_checkpoint_fast( ...
                        'END_RUN', num_zsteps, z_end, prop_code_start, ...
                        memmon_time_vec, memmon_mem_vec, num_zsteps, ...
                        memmon_last_gb, memmon_peak_gb, memmon_warn_state, memmon_cfg);
            catch me
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, 'end', 'memmon_endrun_failed', ...
                    'CerUPP:MemMon:MonitorFailure', ...
                    'MEMMON end-of-run checkpoint failed (%s): %s. Continuing.', ...
                    'END_RUN', me.message);
            end
        else
            if isfinite(terminal_memmon_last_gb)
                memmon_last_gb = double(terminal_memmon_last_gb);
            end
            if isfinite(terminal_memmon_peak_gb)
                if ~isfinite(memmon_peak_gb)
                    memmon_peak_gb = double(terminal_memmon_peak_gb);
                else
                    memmon_peak_gb = max(double(memmon_peak_gb), double(terminal_memmon_peak_gb));
                end
            end
        end
    end

    warn_states = run_warn_state_utils.build_warning_ledger_bundle( ...
        run_warn_state, warn_states_in.plasma, warn_states_in.nla, memmon_warn_state);
    end_ctx.warn_states = warn_states;
    end_ctx.memmon_time_vec = memmon_time_vec;
    end_ctx.memmon_mem_vec = memmon_mem_vec;
    end_ctx.memmon_last_gb = memmon_last_gb;
    end_ctx.memmon_peak_gb = memmon_peak_gb;
end

function end_ctx = emit_run_end_warning_summaries_core_local(end_ctx)
% Canonical struct-owned implementation for end-of-run warning-summary emission.

    if isempty(end_ctx) || ~isstruct(end_ctx) || ~isscalar(end_ctx)
        error('CerUPP:WarningUtils:InvalidEndContext', ...
            'end_ctx must be a struct for the canonical end-of-run warning path.');
    end
    source_tag = struct_utils.req_struct_field(end_ctx, 'source_tag', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    warn_states_in = struct_utils.req_struct_field(end_ctx, 'warn_states', ...
        'CerUPP:WarningUtils:MissingEndContextField');
    reset_after_emit = struct_utils.opt_struct_field(end_ctx, 'reset_after_emit', false);

    if isstring(source_tag) && isscalar(source_tag)
        source_tag = char(source_tag);
    end
    if ~(ischar(source_tag) && ~isempty(source_tag))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.source_tag must be a nonempty char/string scalar.');
    end
    if ~(isscalar(reset_after_emit) && (islogical(reset_after_emit) || isnumeric(reset_after_emit)))
        error('CerUPP:WarningUtils:InvalidEndContextField', ...
            'end_ctx.reset_after_emit must be a scalar logical/numeric flag when provided.');
    end
    reset_after_emit = logical(reset_after_emit);

    warn_states_in = run_warn_state_utils.require_warning_ledger_bundle( ...
        warn_states_in, struct(), struct(), ...
        'CerUPP:WarningUtils:MissingWarnBundle');
    run_warn_state = warn_states_in.run;
    plasma_warn_state = warn_states_in.plasma;
    nla_warn_state = warn_states_in.nla;
    memmon_warn_state = warn_states_in.memmon;

    plasma_summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    nla_summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    if warning_utils_plasma_softwarn_summary_needed_local(plasma_warn_state)
        [plasma_warn_state, plasma_summary_records] = emit_plasma_softwarn_summary_from_state( ...
            plasma_warn_state, source_tag, reset_after_emit);
    end
    if warning_utils_nla_softwarn_summary_needed_local(nla_warn_state)
        [nla_warn_state, nla_summary_records] = emit_nla_softwarn_summary_from_state( ...
            nla_warn_state, source_tag, reset_after_emit);
    end

    for ii = 1:numel(plasma_summary_records)
        run_warn_state = run_warn_state_utils.emit_softwarn_each_time_with_phase( ...
            run_warn_state, 'end', plasma_summary_records(ii).canon_id, ...
            '%s', plasma_summary_records(ii).msg_text);
    end
    for ii = 1:numel(nla_summary_records)
        run_warn_state = run_warn_state_utils.emit_softwarn_each_time_with_phase( ...
            run_warn_state, 'end', nla_summary_records(ii).canon_id, ...
            '%s', nla_summary_records(ii).msg_text);
    end

    run_warn_state = run_warn_state_utils.emit_summary( ...
        run_warn_state, source_tag, reset_after_emit);
    end_ctx.warn_states = run_warn_state_utils.build_warning_ledger_bundle( ...
        run_warn_state, plasma_warn_state, nla_warn_state, memmon_warn_state);
end

function [soft_warn_state, summary_records] = emit_plasma_softwarn_summary_from_state( ...
        soft_warn_state, source_tag, reset_after_emit)
% Build aggregated plasma soft-warning summary records from pass-through state.
% If reset_after_emit=true, the returned soft_warn_state is cleared to
% struct() after emission or after the no-summary fast return.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    if nargin < 1 || isempty(soft_warn_state) || ~isstruct(soft_warn_state)
        soft_warn_state = struct();
    end
    if nargin < 2 || isempty(source_tag)
        source_tag = 'plasma';
    end
    if nargin < 3 || isempty(reset_after_emit)
        reset_after_emit = false;
    end
    if ~plasma_setup_support.summary_needed(soft_warn_state)
        if reset_after_emit
            soft_warn_state = struct();
        end
        return;
    end
    soft_warn_summary = plasma_setup_support.summary_view(soft_warn_state);
    summary_records = [summary_records; ...
        warning_utils_emit_plasma_stage_softwarn_summary_local(soft_warn_summary, source_tag); ...
        warning_utils_emit_plasma_exponent_softwarn_summary_local(soft_warn_summary, source_tag); ...
        warning_utils_emit_plasma_keldysh_softwarn_summary_local(soft_warn_summary, source_tag); ...
        warning_utils_emit_plasma_rho_softwarn_summary_local(soft_warn_summary, source_tag); ...
        warning_utils_emit_plasma_exact_ledger_summary_local( ...
            soft_warn_summary, source_tag); ...
        warning_utils_emit_plasma_diag_fail_softwarn_summary_local(soft_warn_summary, source_tag)];
    if reset_after_emit
        soft_warn_state = struct();
    end
end

function [soft_warn_state, summary_records] = emit_nla_softwarn_summary_from_state( ...
        soft_warn_state, source_tag, reset_after_emit)
% Build aggregated NLA soft-warning summary records from pass-through state.
% If reset_after_emit=true, the returned soft_warn_state is cleared to
% struct() after emission or after the no-summary fast return.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    if nargin < 1 || isempty(soft_warn_state) || ~isstruct(soft_warn_state)
        soft_warn_state = struct();
    end
    if nargin < 2 || isempty(source_tag)
        source_tag = 'nla';
    end
    if nargin < 3 || isempty(reset_after_emit)
        reset_after_emit = false;
    end
    if ~warning_utils_nla_softwarn_summary_needed_local(soft_warn_state)
        if reset_after_emit
            soft_warn_state = struct();
        end
        return;
    end
    soft_warn_summary = warning_utils_nla_softwarn_summary_view_local(soft_warn_state);
    summary_records = [summary_records; ...
        warning_utils_emit_nla_ratio_gain_softwarn_summary_local(soft_warn_summary, source_tag); ...
        warning_utils_emit_nla_neutral_clamp_softwarn_summary_local(soft_warn_summary, source_tag)];
    if reset_after_emit
        soft_warn_state = struct();
    end
end

function summary_records = warning_utils_emit_plasma_stage_softwarn_summary_local( ...
        soft_warn_summary, source_tag)
% Build one ordered plasma-stage summary block from the canonical summary view.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    stage_names = plasma_setup_support.stage_names();
    for kk = 1:numel(stage_names)
        stage = stage_names{kk};
        stage_label = plasma_setup_support.stage_label(stage);
        stage_rec = soft_warn_summary.stages.(stage);

        complex_count = stage_rec.complex_count;
        if complex_count > 0
            first_it = stage_rec.complex_first_it;
            first_idx = stage_rec.complex_first_linear_idx;
            complex_max_imag = stage_rec.complex_max_imag;
            complex_max_tol = stage_rec.complex_max_tol;
            if isfinite(first_it) && isfinite(first_idx)
                [msg_text, ~] = warning_utils_render_warning_message_local( ...
                    ['%s: %s complex-leakage soft events=%d (max|imag|=%.3e, max tol=%.3e, ' ...
                     'first_it=%d, first_linear_idx=%d).'], ...
                    source_tag, stage_label, complex_count, ...
                    complex_max_imag, complex_max_tol, ...
                    round(first_it), round(first_idx));
            else
                [msg_text, ~] = warning_utils_render_warning_message_local( ...
                    '%s: %s complex-leakage soft events=%d (max|imag|=%.3e, max tol=%.3e).', ...
                    source_tag, stage_label, complex_count, ...
                    complex_max_imag, complex_max_tol);
            end
            summary_records(end+1, 1) = struct( ...
                'canon_id', 'CerUPP:Plasma:SoftComplexSummary', ...
                'msg_text', msg_text);
        end

        bounds_count = stage_rec.bounds_count;
        if bounds_count > 0
            [msg_text, ~] = warning_utils_render_warning_message_local( ...
                '%s: %s bounds soft events=%d (min=%.3e, max=%.3e, max tol=%.3e).', ...
                source_tag, stage_label, bounds_count, ...
                stage_rec.bounds_min, stage_rec.bounds_max, stage_rec.bounds_max_tol);
            summary_records(end+1, 1) = struct( ...
                'canon_id', 'CerUPP:Plasma:SoftBoundsSummary', ...
                'msg_text', msg_text);
        end
    end
end

function summary_records = warning_utils_emit_plasma_exponent_softwarn_summary_local( ...
        soft_warn_summary, source_tag)
% Build exponent-clamp plasma summary records when present.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    exponent_rec = soft_warn_summary.exponent_soft_clamp;
    if exponent_rec.count > 0
        [msg_text, ~] = warning_utils_render_warning_message_local( ...
            ['%s: exponent clamp soft events=%d (OFI=%d, avalanche=%d, max|expo_raw|=%.3e at I=%.3e W/m^2, stage=%s, raw_min=%.3e, raw_max=%.3e). ', ...
             'Clamp indicates exp-argument saturation at numerical guard bounds.'], ...
            source_tag, exponent_rec.count, ...
            exponent_rec.ofi_count, exponent_rec.aval_count, ...
            exponent_rec.max_abs_raw, exponent_rec.i_at_worst, ...
            exponent_rec.worst_stage, exponent_rec.raw_min, exponent_rec.raw_max);
        summary_records(end+1, 1) = struct( ...
            'canon_id', 'CerUPP:Plasma:SoftExponentClampSummary', ...
            'msg_text', msg_text);
    end
end

function summary_records = warning_utils_emit_plasma_keldysh_softwarn_summary_local( ...
        soft_warn_summary, source_tag)
% Build Keldysh runtime-domain plasma summary records when present.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    keldysh_rec = soft_warn_summary.keldysh_lut;
    if (keldysh_rec.zero_count > 0) || (keldysh_rec.low_count > 0) || ...
            (keldysh_rec.high_count > 0)
        [msg_text, ~] = warning_utils_render_warning_message_local( ...
            ['%s: Keldysh runtime domain handling observed (events=%d, ', ...
             'I<I_zero_below zeroed=%d, I_zero_below<=I<I_min zeroed=%d, ', ...
             'I>I_max count=%d, max I_raw=%.3e W/m^2, first stage=%s).'], ...
            source_tag, keldysh_rec.event_count, keldysh_rec.zero_count, ...
            keldysh_rec.low_count, keldysh_rec.high_count, ...
            keldysh_rec.max_i_raw, keldysh_rec.first_stage);
        summary_records(end+1, 1) = struct( ...
            'canon_id', 'CerUPP:Plasma:SoftKeldyshLUTClampSummary', ...
            'msg_text', msg_text);
    end
end

function summary_records = warning_utils_emit_plasma_rho_softwarn_summary_local( ...
        soft_warn_summary, source_tag)
% Build rho-clamp plasma summary records when present.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    rho_rec = soft_warn_summary.rho_clamp;
    if rho_rec.count > 0
        [msg_text, ~] = warning_utils_render_warning_message_local( ...
            ['%s: rho bound clamp events=%d (half=%d, next=%d, max cap=%.3e). ', ...
             'This indicates rho stage updates hit [0, rho_plasma_cap] saturation guards.'], ...
            source_tag, rho_rec.count, rho_rec.half_count, ...
            rho_rec.next_count, rho_rec.cap_value_max);
        summary_records(end+1, 1) = struct( ...
            'canon_id', 'CerUPP:Plasma:SoftRhoClampSummary', ...
            'msg_text', msg_text);
    end
end

function summary_records = warning_utils_emit_plasma_diag_fail_softwarn_summary_local( ...
        soft_warn_summary, source_tag)
% Build plasma diagnostic-sampling summary records when present.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    diag_fail_rec = soft_warn_summary.diag_sample_failed;
    if diag_fail_rec.count > 0
        [msg_text, ~] = warning_utils_render_warning_message_local( ...
            '%s: plasma stiffness diagnostic sampling failed %d time(s) (first message: %s).', ...
            source_tag, diag_fail_rec.count, diag_fail_rec.first_message);
        summary_records(end+1, 1) = struct( ...
            'canon_id', 'CerUPP:Plasma:DiagSampleFailedSummary', ...
            'msg_text', msg_text);
    end
end

function summary_records = warning_utils_emit_plasma_exact_ledger_summary_local( ...
        soft_warn_summary, source_tag)
% Build exact-ledger replay summary records when present.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    ledger_rec = soft_warn_summary.exact_ledger_replay_failed;
    if ledger_rec.count > 0
        [msg_text, ~] = warning_utils_render_warning_message_local( ...
            ['%s: exact-frozen mechanism-ledger replay failed %d time(s); the rho updates ', ...
             'were kept and the per-mechanism partition diagnostics were marked invalid ', ...
             '(first message: %s).'], ...
            source_tag, ledger_rec.count, ledger_rec.first_message);
        summary_records(end+1, 1) = struct( ...
            'canon_id', 'CerUPP:Plasma:ExactLedgerReplayFailedSummary', ...
            'msg_text', msg_text);
    end
    ledger_accounting_rec = soft_warn_summary.exact_ledger_accounting_failed;
    if ledger_accounting_rec.count > 0
        [msg_text, ~] = warning_utils_render_warning_message_local( ...
            ['%s: exact-frozen mechanism-ledger accounting failed %d time(s); the already computed ', ...
             'rho updates were kept and the per-mechanism partition diagnostics were marked invalid ', ...
             '(first message: %s).'], ...
            source_tag, ledger_accounting_rec.count, ...
            ledger_accounting_rec.first_message);
        summary_records(end+1, 1) = struct( ...
            'canon_id', 'CerUPP:Plasma:ExactLedgerAccountingFailedSummary', ...
            'msg_text', msg_text);
    end
end

function soft_warn_summary = warning_utils_nla_softwarn_summary_view_local(soft_warn_state)
% Build one compact NLA summary view so the generic summary shell can stay table-driven.

    soft_warn_summary = struct( ...
        'ratio_gain', struct( ...
            'event_count', run_warn_state_utils.state_value(soft_warn_state, 'ratio_gain_clamp_event_count', 0, 'num'), ...
            'sample_count', run_warn_state_utils.state_value(soft_warn_state, 'ratio_gain_clamp_sample_count', 0, 'num'), ...
            'max_ratio', run_warn_state_utils.state_value(soft_warn_state, 'ratio_gain_clamp_max_ratio', NaN, 'num'), ...
            'tol', run_warn_state_utils.state_value(soft_warn_state, 'ratio_gain_clamp_tol', NaN, 'num')), ...
        'neutral_clamp', struct( ...
            'sample_count', run_warn_state_utils.state_value(soft_warn_state, 'neutral_frac_clamp_count', 0, 'num'), ...
            'event_count', run_warn_state_utils.state_value(soft_warn_state, 'neutral_frac_clamp_event_count', 0, 'num'), ...
            'low_count', run_warn_state_utils.state_value(soft_warn_state, 'neutral_frac_clamp_low_count', 0, 'num'), ...
            'high_count', run_warn_state_utils.state_value(soft_warn_state, 'neutral_frac_clamp_high_count', 0, 'num'), ...
            'raw_min', run_warn_state_utils.state_value(soft_warn_state, 'neutral_frac_raw_min', NaN, 'num'), ...
            'raw_max', run_warn_state_utils.state_value(soft_warn_state, 'neutral_frac_raw_max', NaN, 'num')));
end

function summary_records = warning_utils_emit_nla_ratio_gain_softwarn_summary_local( ...
        soft_warn_summary, source_tag)
% Build NLA ratio-gain summary records when present.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    ratio_gain_event_count = soft_warn_summary.ratio_gain.event_count;
    if ratio_gain_event_count > 0
        [msg_text, ~] = warning_utils_render_warning_message_local( ...
            ['%s: NLA ratio-gain clamps observed %d time(s) across %d sample(s) ', ...
             '(max_ratio=%.6e, tol=%.3e).'], ...
            source_tag, ratio_gain_event_count, soft_warn_summary.ratio_gain.sample_count, ...
            soft_warn_summary.ratio_gain.max_ratio, soft_warn_summary.ratio_gain.tol);
        summary_records(end+1, 1) = struct( ...
            'canon_id', 'CerUPP:NLA:RatioGainClampedSummary', ...
            'msg_text', msg_text);
    end
end

function summary_records = warning_utils_emit_nla_neutral_clamp_softwarn_summary_local( ...
        soft_warn_summary, source_tag)
% Build NLA neutral-clamp summary records when present.

    summary_records = repmat(struct('canon_id', '', 'msg_text', ''), 0, 1);
    clamp_count = soft_warn_summary.neutral_clamp.sample_count;
    if clamp_count > 0
        [msg_text, ~] = warning_utils_render_warning_message_local( ...
            ['%s: NLA neutral-fraction clamp events=%d samples (events=%d, below0=%d, above1=%d, ' ...
             'raw_min=%.3e, raw_max=%.3e).'], ...
            source_tag, clamp_count, ...
            soft_warn_summary.neutral_clamp.event_count, ...
            soft_warn_summary.neutral_clamp.low_count, ...
            soft_warn_summary.neutral_clamp.high_count, ...
            soft_warn_summary.neutral_clamp.raw_min, ...
            soft_warn_summary.neutral_clamp.raw_max);
        summary_records(end+1, 1) = struct( ...
            'canon_id', 'CerUPP:NLA:SoftNeutralClampSummary', ...
            'msg_text', msg_text);
    end
end

function tf = warning_utils_plasma_softwarn_summary_needed_local(soft_warn_state)
% Cheap preflight to skip plasma summary scans when all counters are zero.

    tf = plasma_setup_support.summary_needed(soft_warn_state);
end

function tf = warning_utils_nla_softwarn_summary_needed_local(soft_warn_state)
% Cheap preflight to skip NLA summary scans when all counters are zero.

    tf = false;
    if nargin < 1 || ~isstruct(soft_warn_state) || isempty(fieldnames(soft_warn_state))
        return;
    end
    field_names = {'ratio_gain_clamp_event_count', 'neutral_frac_clamp_count'};
    for ii = 1:numel(field_names)
        if run_warn_state_utils.state_value(soft_warn_state, field_names{ii}, 0, 'num') > 0
            tf = true;
            return;
        end
    end
end
