classdef run_warn_state_utils
% RUN_WARN_STATE_UTILS Shared warning emission, warning-state, and end-of-run summary helpers.
% Purpose:
% - Keep the driver-owned warning ledger in one place across setup,
%   propagation, and end-of-run summary output.
% - Output-I/O failure/info ledger ownership lives in output_io_warn_utils.
% Called mainly from cerupp.m, checkpoint_utils.m, and cerupp_section6a_postprocess.m.

    methods (Static)
        function run_warn_state = emit_warn_once_with_phase( ...
                run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin)
        % EMIT_WARN_ONCE_WITH_PHASE Emit one warn-once warning and, only if
        % it actually prints, count one event in the requested phase bucket.
        % Disabled or already-latched warnings do not increment the phase
        % summary. The caller passes phase_tag, warn_key, canon_id, and
        % msg_fmt explicitly.

            run_warn_state = run_warn_state_utils.emit_phase_warning_local( ...
                run_warn_state, phase_tag, 'warn_once_emit', warn_key, canon_id, msg_fmt, varargin{:});
        end

        function run_warn_state = emit_softwarn_each_time_with_phase( ...
                run_warn_state, phase_tag, canon_id, msg_fmt, varargin)
        % EMIT_SOFTWARN_EACH_TIME_WITH_PHASE Emit a non-deduplicated warning
        % and, only if it actually prints, count one event in the requested
        % phase bucket. Disabled warning IDs do not increment the phase
        % summary. The caller passes phase_tag, canon_id, and msg_fmt
        % explicitly.

            run_warn_state = run_warn_state_utils.emit_phase_warning_local( ...
                run_warn_state, phase_tag, 'softwarn_occurrence', '', canon_id, msg_fmt, varargin{:});
        end

        function [run_warn_state, emitted_now, msg_txt, format_failed] = ...
                emit_warn_once_with_phase_message( ...
                run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin)
        % EMIT_WARN_ONCE_WITH_PHASE_MESSAGE Emit one run-owned warn-once warning and return the retained message details.

            [run_warn_state, emitted_now, msg_txt, format_failed] = ...
                run_warn_state_utils.emit_phase_warning_local( ...
                    run_warn_state, phase_tag, 'warn_once_emit', warn_key, canon_id, msg_fmt, varargin{:});
        end

        function [run_warn_state, emitted_now, msg_txt, format_failed] = ...
                emit_softwarn_each_time_with_phase_message( ...
                run_warn_state, phase_tag, canon_id, msg_fmt, varargin)
        % EMIT_SOFTWARN_EACH_TIME_WITH_PHASE_MESSAGE Emit one run-owned soft warning and return the retained message details.

            [run_warn_state, emitted_now, msg_txt, format_failed] = ...
                run_warn_state_utils.emit_phase_warning_local( ...
                    run_warn_state, phase_tag, 'softwarn_occurrence', '', canon_id, msg_fmt, varargin{:});
        end

        function [run_warn_state, msg_txt] = emit_info_with_phase( ...
                run_warn_state, phase_tag, info_key, msg_fmt, varargin)
        % EMIT_INFO_WITH_PHASE Emit one run-owned informational line through the shared warning/info owner.

            run_warn_state = run_warn_state_utils.normalize_run_warn_state_local(run_warn_state);
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidEmitWarningPhaseTag');
            [run_warn_state, msg_txt] = warning_utils.cerupp_info_with_state( ...
                run_warn_state, phase_tag, info_key, msg_fmt, varargin{:});
        end

        function [bucket_warn_state, emitted_now] = emit_bucket_warn_once( ...
                bucket_warn_state, bucket_name, warn_key, canon_id, msg_fmt, varargin)
        % EMIT_BUCKET_WARN_ONCE Emit one warn-once warning through a named
        % sub-ledger such as plasma, nla, or memmon.

            bucket_name = run_warn_state_utils.normalize_bucket_name_local(bucket_name);
            bucket_warn_state = run_warn_state_utils.normalize_soft_warn_state_local( ...
                bucket_warn_state, bucket_name);
            [bucket_warn_state, emitted_now] = warning_utils.cerupp_warn_once( ...
                bucket_warn_state, warn_key, canon_id, msg_fmt, varargin{:});
        end

        function [bucket_warn_state, msg_txt] = emit_bucket_info_with_phase( ...
                bucket_warn_state, bucket_name, phase_tag, info_key, msg_fmt, varargin)
        % EMIT_BUCKET_INFO_WITH_PHASE Emit one informational line through a named sub-ledger such as plasma/nla/memmon.

            bucket_name = run_warn_state_utils.normalize_bucket_name_local(bucket_name);
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidEmitWarningPhaseTag');
            bucket_warn_state = run_warn_state_utils.normalize_soft_warn_state_local( ...
                bucket_warn_state, bucket_name);
            [bucket_warn_state, msg_txt] = warning_utils.cerupp_info_with_state( ...
                bucket_warn_state, phase_tag, info_key, msg_fmt, varargin{:});
        end

        function [flag, run_warn_state] = latch_off_after_failure( ...
                flag, run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin)
        % LATCH_OFF_AFTER_FAILURE Emit one phase-tagged warning, then force
        % the flag off. The caller provides the phase tag and warning ID.

            if nargin < 1
                flag = false;
            end
            if nargin < 2 || ~isstruct(run_warn_state)
                run_warn_state = struct();
            end
            if nargin < 3 || isempty(phase_tag)
                error('CerUPP:MissingPhaseTag', ...
                    'phase_tag is required for latch_off_after_failure.');
            end
            if nargin < 4 || isempty(warn_key)
                error('CerUPP:MissingPhaseWarnKey', ...
                    'warn_key is required for latch_off_after_failure.');
            end
            if nargin < 5 || isempty(canon_id)
                error('CerUPP:MissingPhaseWarningID', ...
                    'canon_id is required for latch_off_after_failure.');
            end
            if nargin < 6 || isempty(msg_fmt)
                error('CerUPP:MissingPhaseWarningMessage', ...
                    'msg_fmt is required for latch_off_after_failure.');
            end
            if logical(flag)
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin{:});
                flag = false;
            end
        end

        function run_warn_state = record_warning_phase_event( ...
                run_warn_state, phase_tag, warn_id, warn_msg, event_kind)
        % RECORD_WARNING_PHASE_EVENT Record one warning event under
        % run_warn_state.warning_phase.(phase_tag).
        % warn_msg may be text or a struct carrying text plus
        % format_failed metadata. The stored record keeps per-phase totals
        % plus the first warning ID and the last warning ID/message used by summaries.

            run_warn_state = run_warn_state_utils.normalize_run_warn_state_local(run_warn_state);
            if nargin < 3 || isempty(warn_id)
                error('CerUPP:MissingWarningPhaseID', ...
                    'record_warning_phase_event requires an explicit warn_id.');
            end
            if nargin < 4
                error('CerUPP:MissingWarningPhaseMessage', ...
                    'record_warning_phase_event requires an explicit warn_msg (pass '''' for none).');
            end
            if isempty(warn_msg)
                warn_msg = '';
            end
            if nargin < 5 || isempty(event_kind)
                event_kind = 'direct_record';
            end
            event_kind = run_warn_state_utils.normalize_internal_event_kind_local(event_kind);
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidEmitWarningPhaseTag');
            warn_id = warning_utils.normalize_warning_id(warn_id);
            [warn_msg, format_failed] = run_warn_state_utils.normalize_recorded_warning_message_local(warn_msg);
            run_warn_state = run_warn_state_utils.initialize_warning_phase_schema_local(run_warn_state);
            phase_field = phase_tag;
            rec = run_warn_state.warning_phase.(phase_field);
            total_event_count = run_warn_state_utils.state_value(rec, 'total_event_count', 0, 'num');
            warn_once_emit_count = run_warn_state_utils.state_value(rec, 'warn_once_emit_count', 0, 'num');
            softwarn_occurrence_count = run_warn_state_utils.state_value(rec, 'softwarn_occurrence_count', 0, 'num');
            direct_record_count = run_warn_state_utils.state_value(rec, 'direct_record_count', 0, 'num');
            format_failed_count = run_warn_state_utils.state_value(rec, 'format_failed_count', 0, 'num');
            total_event_count = total_event_count + 1;
            switch event_kind
                case 'warn_once_emit'
                    warn_once_emit_count = warn_once_emit_count + 1;
                case 'softwarn_occurrence'
                    softwarn_occurrence_count = softwarn_occurrence_count + 1;
                case 'direct_record'
                    direct_record_count = direct_record_count + 1;
            end
            if format_failed
                format_failed_count = format_failed_count + 1;
            end
            rec.total_event_count = total_event_count;
            rec.warn_once_emit_count = warn_once_emit_count;
            rec.softwarn_occurrence_count = softwarn_occurrence_count;
            rec.direct_record_count = direct_record_count;
            rec.format_failed_count = format_failed_count;
            if (~isfield(rec, 'first_id') || isempty(rec.first_id)) && ~isempty(warn_id)
                rec.first_id = warn_id;
            end
            rec.last_id = warn_id;
            rec.last_message = warn_msg;
            rec.last_message_format_failed = logical(format_failed);
            if strcmp(phase_field, 'end') && ...
                    run_warn_state_utils.is_isosurface_skip_warning_id_local(warn_id)
                rec = run_warn_state_utils.accumulate_isosurface_skip_summary_local( ...
                    rec, 1, warn_msg);
            end
            run_warn_state.warning_phase.(phase_field) = rec;
        end

    end

    methods (Static, Access = private)
        function field_names = warning_ledger_bundle_field_names()

        % WARNING_LEDGER_BUNDLE_FIELD_NAMES Canonical required warning-ledger bundle fields.
            field_names = {'run', 'plasma', 'nla', 'memmon'};
        end

        function [run_warn_state, emitted_now, msg_txt, format_failed] = emit_phase_warning_local( ...
                run_warn_state, phase_tag, event_kind, warn_key, canon_id, msg_fmt, varargin)
        % EMIT_PHASE_WARNING_LOCAL Shared phase-aware warning emission owner.

            run_warn_state = run_warn_state_utils.normalize_run_warn_state_local(run_warn_state);
            emitted_now = false;
            msg_txt = '';
            format_failed = false;
            if nargin < 3 || isempty(event_kind)
                error('run_warn_state_utils:MissingPhaseWarningEventKind', ...
                    'emit_phase_warning_local requires an explicit event_kind.');
            end
            event_kind = run_warn_state_utils.normalize_internal_event_kind_local(event_kind);
            if nargin < 6 || isempty(msg_fmt)
                error('run_warn_state_utils:MissingPhaseWarningMessage', ...
                    'emit_phase_warning_local requires an explicit msg_fmt.');
            end
            switch event_kind
                case 'warn_once_emit'
                    if nargin < 4 || isempty(warn_key)
                        error('run_warn_state_utils:MissingPhaseWarnKey', ...
                            'warn_once phase warnings require an explicit warn_key.');
                    end
                    if nargin < 5 || isempty(canon_id)
                        error('run_warn_state_utils:MissingPhaseWarningID', ...
                            'warn_once phase warnings require an explicit canon_id.');
                    end
                    canon_id = warning_utils.normalize_warning_id(canon_id);
                    [run_warn_state, emitted_now, msg_txt, format_failed] = ...
                        warning_utils.cerupp_warn_once_with_message( ...
                            run_warn_state, warn_key, canon_id, msg_fmt, varargin{:});
                case 'softwarn_occurrence'
                    if nargin < 5 || isempty(canon_id)
                        error('run_warn_state_utils:MissingPhaseWarningID', ...
                            'softwarn phase warnings require an explicit canon_id.');
                    end
                    canon_id = warning_utils.normalize_warning_id(canon_id);
                    [msg_txt, format_failed, emitted_now] = warning_utils.cerupp_warn_with_message( ...
                        canon_id, msg_fmt, varargin{:});
                otherwise
                    error('run_warn_state_utils:InvalidPhaseWarningEventKind', ...
                        'Unsupported phase warning emission kind "%s".', event_kind);
            end
            if emitted_now
                run_warn_state = run_warn_state_utils.record_warning_phase_event( ...
                    run_warn_state, phase_tag, canon_id, ...
                    struct('text', msg_txt, 'format_failed', format_failed), ...
                    event_kind);
            end
        end

        function bucket_name = normalize_bucket_name_local(bucket_name)
        % NORMALIZE_BUCKET_NAME_LOCAL Validate the supported non-run warning sub-ledger names.

            if isstring(bucket_name) && isscalar(bucket_name)
                bucket_name = char(bucket_name);
            end
            if ~ischar(bucket_name)
                error('CerUPP:InvalidWarningBucketName', ...
                    'bucket_name must be a char/string scalar.');
            end
            bucket_name = lower(strtrim(bucket_name));
            if ~ismember(bucket_name, {'plasma', 'nla', 'memmon'})
                error('CerUPP:InvalidWarningBucketName', ...
                    'bucket_name must be ''plasma'', ''nla'', or ''memmon''; got ''%s''.', bucket_name);
            end
        end
    end

    methods (Static)
        function warn_bundle = build_warning_ledger_bundle( ...
                run_warn_state, plasma_warn_state, nla_warn_state, memmon_warn_state)
        % BUILD_WARNING_LEDGER_BUNDLE Build the closed
        % run/plasma/nla/memmon warning bundle used by driver/restart code.

            if nargin < 1, run_warn_state = struct(); end
            if nargin < 2, plasma_warn_state = struct(); end
            if nargin < 3, nla_warn_state = struct(); end
            if nargin < 4, memmon_warn_state = struct(); end
            warn_bundle = struct();
            warn_bundle.run = struct_utils.clone_warned_keys_map( ...
                run_warn_state_utils.normalize_run_warn_state_local(run_warn_state));
            warn_bundle.plasma = struct_utils.clone_warned_keys_map( ...
                run_warn_state_utils.normalize_soft_warn_state_local(plasma_warn_state, 'plasma'));
            warn_bundle.nla = struct_utils.clone_warned_keys_map( ...
                run_warn_state_utils.normalize_soft_warn_state_local(nla_warn_state, 'nla'));
            warn_bundle.memmon = struct_utils.clone_warned_keys_map( ...
                run_warn_state_utils.normalize_soft_warn_state_local(memmon_warn_state, 'memmon'));
        end

        function warn_bundle = require_warning_ledger_bundle( ...
                warn_bundle_in, run_warn_state_default, memmon_warn_state_default, caller_id)
        % REQUIRE_WARNING_LEDGER_BUNDLE Require the full
        % run/plasma/nla/memmon warning bundle and normalize each piece.
        % Empty run or memmon ledgers inherit the caller-supplied defaults
        % before the bundle is normalized.

            if nargin < 2 || isempty(run_warn_state_default)
                run_warn_state_default = struct();
            end
            if nargin < 3 || isempty(memmon_warn_state_default)
                memmon_warn_state_default = struct();
            end
            if nargin < 4 || isempty(caller_id)
                caller_id = 'CerUPP:MissingWarnBundle';
            end
            field_names = run_warn_state_utils.warning_ledger_bundle_field_names();
            if nargin < 1 || ~isstruct(warn_bundle_in) || ~isscalar(warn_bundle_in)
                error(caller_id, ...
                    'warn_bundle_in must be a scalar struct with fields: %s.', ...
                    strjoin(field_names, ', '));
            end
            missing_fields = field_names(~isfield(warn_bundle_in, field_names));
            if ~isempty(missing_fields)
                error(caller_id, ...
                    'warn_bundle_in is missing required field(s): %s.', ...
                    strjoin(missing_fields, ', '));
            end
            run_warn_state = warn_bundle_in.run;
            if isempty(run_warn_state)
                run_warn_state = run_warn_state_default;
            end
            memmon_warn_state = warn_bundle_in.memmon;
            if isempty(memmon_warn_state)
                memmon_warn_state = memmon_warn_state_default;
            end
            warn_bundle = run_warn_state_utils.build_warning_ledger_bundle( ...
                run_warn_state, ...
                warn_bundle_in.plasma, ...
                warn_bundle_in.nla, ...
                memmon_warn_state);
        end

        function msg_txt = sanitize_warn_message_text(msg_txt)
        % SANITIZE_WARN_MESSAGE_TEXT Normalize retained warning text for summary storage.
        % Converts scalar strings to char and flattens embedded newline/
        % carriage-return characters to spaces before storage/emission in
        % compact summaries.

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

        function [msg_txt, format_failed] = normalize_recorded_warning_message_local(msg_in)
        % NORMALIZE_RECORDED_WARNING_MESSAGE_LOCAL Normalize retained summary text plus format-failure metadata.
        % Accepts scalar text, scalar printable numeric/logical values, or
        % a struct carrying text plus format_failed metadata; retained text
        % is flattened through SANITIZE_WARN_MESSAGE_TEXT before storage.

            format_failed = false;
            if nargin < 1 || isempty(msg_in)
                msg_txt = '';
                return;
            end
            if isstruct(msg_in)
                if ~isscalar(msg_in) || ~isfield(msg_in, 'text')
                    error('CerUPP:InvalidWarningPhaseMessage', ...
                        'warn_msg struct inputs must be scalar and include a text field.');
                end
                [msg_txt, nested_format_failed] = ...
                    run_warn_state_utils.normalize_recorded_warning_message_local(msg_in.text);
                format_failed = nested_format_failed;
                if isfield(msg_in, 'format_failed')
                    format_flag = msg_in.format_failed;
                    if ~(islogical(format_flag) && isscalar(format_flag))
                        error('CerUPP:InvalidWarningPhaseMessage', ...
                            'warn_msg.format_failed must be a logical scalar.');
                    end
                    format_failed = format_failed || logical(format_flag);
                end
                return;
            elseif ischar(msg_in)
                msg_txt = msg_in;
            elseif isstring(msg_in) && isscalar(msg_in)
                msg_txt = char(msg_in);
            elseif islogical(msg_in) && isscalar(msg_in)
                msg_txt = mat2str(msg_in);
            elseif isnumeric(msg_in) && isscalar(msg_in) && isreal(msg_in)
                msg_txt = mat2str(msg_in);
            else
                error('CerUPP:InvalidWarningPhaseMessage', ...
                    ['warn_msg must be scalar text or a scalar printable numeric/logical value; ' ...
                     'got %s.'], ...
                    class(msg_in));
            end
            msg_txt = run_warn_state_utils.sanitize_warn_message_text(msg_txt);
        end

        function v = state_value(s, field_name, default_value, field_kind)
        % STATE_VALUE Warning-summary accessor with default fallback.

            if nargin < 4 || isempty(field_kind)
                field_kind = 'num';
            end
            if nargin < 3
                default_value = [];
            end
            if nargin < 1 || isempty(s)
                v = run_warn_state_utils.normalize_optional_state_value_local( ...
                    default_value, field_name, field_kind);
                return;
            end
            if ~(isstruct(s) && isscalar(s))
                error('CerUPP:InvalidWarningStateCarrier', ...
                    'Expected a scalar struct carrier while reading %s field "%s".', ...
                    field_kind, field_name);
            end
            if ~isfield(s, field_name) || isempty(s.(field_name))
                v = run_warn_state_utils.normalize_optional_state_value_local( ...
                    default_value, field_name, field_kind);
                return;
            end
            v = run_warn_state_utils.normalize_optional_state_value_local( ...
                s.(field_name), field_name, field_kind);
        end

        function run_warn_state = emit_summary(run_warn_state, source_tag, reset_after_emit)
        % EMIT_SUMMARY Emit end-of-run summaries for driver-owned warning state.
        % Category descriptors (for example "[setup soft warn]") are attached
        % to phase/output summaries for easier lifecycle auditing.
        % Emitted summary strings are compacted for readability while raw
        % stored state remains unchanged.
        % If reset_after_emit is true, this method clears the emitted
        % driver-owned summary ledgers while preserving the surrounding
        % run_warn_state struct.

            if nargin < 2 || isempty(source_tag)
                source_tag = 'run_end';
            end
            if nargin < 3 || isempty(reset_after_emit)
                reset_after_emit = false;
            end
            [run_warn_state, summary_scan] = run_warn_state_utils.scan_summary_content_local(run_warn_state);
            if ~summary_scan.has_content
                return;
            end

            if summary_scan.isosurface_skip_has_content
                end_phase_field = run_warn_state_utils.resolve_phase_field(run_warn_state, 'end');
                iso_count = 0;
                last_msg = 'n/a';
                if ~isempty(end_phase_field) && isfield(run_warn_state.warning_phase, end_phase_field)
                    end_phase_state = run_warn_state.warning_phase.(end_phase_field);
                    iso_count = run_warn_state_utils.state_value( ...
                        end_phase_state, 'isosurface_skipped_count', 0, 'num');
                    last_msg = run_warn_state_utils.state_value( ...
                        end_phase_state, 'isosurface_skipped_last_message', 'n/a', 'text');
                end
                if iso_count > 0
                    last_msg = run_warn_state_utils.compact_summary_text(last_msg, 160);
                    phase_desc = run_warn_state_utils.phase_softwarn_descriptor('end');
                    run_warn_state_utils.emit_summary_info('end', 'isosurface_skipped_summary', ...
                        source_tag, phase_desc, ...
                        'Isosurface plot skipped %d time(s). Last reason: %s', ...
                        iso_count, last_msg);
                end
            end

            for ii = 1:numel(summary_scan.phase_entries)
                phase_entry = summary_scan.phase_entries(ii);
                if phase_entry.event_count <= 0
                    continue;
                end
                run_warn_state_utils.emit_phase_warning_summary_local(source_tag, phase_entry.name, phase_entry.state);
            end

            if summary_scan.io_has_content
                for ii = 1:numel(summary_scan.io_records)
                    run_warn_state_utils.emit_output_io_summary_record_local( ...
                        summary_scan.io_records(ii), source_tag);
                end
            end

            if reset_after_emit
                run_warn_state = run_warn_state_utils.clear_emitted_summary_ledgers_local(run_warn_state);
            end
        end
    end

    methods (Static, Hidden)
        function run_warn_state = emit_phase_summary(run_warn_state, source_tag, phase_tag, reset_after_emit)
        % EMIT_PHASE_SUMMARY Supported internal lifecycle-boundary summary helper.
        % If reset_after_emit is true, this method clears only the selected
        % canonical warning_phase bucket after emission.

            run_warn_state = run_warn_state_utils.normalize_run_warn_state_local(run_warn_state);
            if nargin < 2 || isempty(source_tag)
                source_tag = 'phase_boundary';
            end
            if nargin < 4 || isempty(reset_after_emit)
                reset_after_emit = false;
            end
            if ~isfield(run_warn_state, 'warning_phase') || ~isstruct(run_warn_state.warning_phase)
                return;
            end
            phase_name = run_warn_state_utils.canonical_phase_name(phase_tag);
            phase_field = run_warn_state_utils.resolve_phase_field(run_warn_state, phase_name);
            if isempty(phase_field) || ~isfield(run_warn_state.warning_phase, phase_field)
                return;
            end
            phase_state = run_warn_state.warning_phase.(phase_field);
            phase_entry = run_warn_state_utils.phase_summary_entry_local(phase_name, phase_state);
            if phase_entry.has_content
                run_warn_state_utils.emit_phase_warning_summary_local(source_tag, phase_entry.name, phase_entry.state);
            end
            if reset_after_emit
                run_warn_state.warning_phase.(phase_field) = run_warn_state_utils.empty_warning_phase_record();
            end
        end

        function txt = compact_summary_text(txt, max_chars)
        % COMPACT_SUMMARY_TEXT Shared emitted-text compaction surface for warning summaries.

            if nargin < 2 || isempty(max_chars)
                max_chars = 160;
            end
            txt = run_warn_state_utils.sanitize_warn_message_text(txt);
            if ~ischar(txt)
                txt = '';
                return;
            end
            txt = strtrim(regexprep(txt, '\s+', ' '));
            if isfinite(max_chars) && (max_chars >= 4) && (numel(txt) > max_chars)
                txt = [txt(1:max_chars-3) '...'];
            end
        end

        function path_txt = compact_summary_path(path_txt, max_chars)
        % COMPACT_SUMMARY_PATH Shared emitted-path compaction surface for warning summaries.

            if nargin < 2 || isempty(max_chars)
                max_chars = 120;
            end
            path_txt = run_warn_state_utils.sanitize_warn_message_text(path_txt);
            if ~ischar(path_txt)
                path_txt = '';
                return;
            end
            path_txt = strtrim(regexprep(path_txt, '\s+', ' '));
            if ~isfinite(max_chars) || (numel(path_txt) <= max_chars)
                return;
            end
            if max_chars < 8
                path_txt = [path_txt(1:max_chars-3) '...'];
                return;
            end
            head_chars = floor((max_chars - 3) / 2);
            tail_chars = max_chars - 3 - head_chars;
            path_txt = [path_txt(1:head_chars) '...' path_txt(end-tail_chars+1:end)];
        end

        function emit_summary_info(phase_tag, info_key, source_tag, category_desc, body_fmt, varargin)
        % EMIT_SUMMARY_INFO Shared compact summary-line formatter for info-event summaries.

            if nargin < 3 || isempty(source_tag)
                source_tag = 'summary';
            end
            if nargin < 4 || isempty(category_desc)
                category_desc = 'summary';
            end
            if nargin < 5 || isempty(body_fmt)
                body_fmt = '%s';
            end
            warning_utils.cerupp_info(phase_tag, info_key, ['%s: [%s] ' body_fmt], ...
                source_tag, category_desc, varargin{:});
        end

        function phase_name = phase_setup()
        % Canonical setup warning phase label for in-repo callers.

            phase_name = 'setup';
        end

        function phase_name = phase_propagation()
        % Canonical propagation warning phase label for in-repo callers.

            phase_name = 'propagation';
        end

        function phase_name = phase_end()
        % Canonical end-of-run warning phase label for in-repo callers.

            phase_name = 'end';
        end
    end

    methods (Static, Hidden)
        function tf = has_summary_content(run_warn_state)
% HAS_SUMMARY_CONTENT Supported internal preflight check for end-of-run summaries.

            [~, summary_scan] = run_warn_state_utils.scan_summary_content_local(run_warn_state);
            tf = summary_scan.has_content;
        end

        function phase_name = canonical_phase_name(phase_tag, error_id)
        % CANONICAL_PHASE_NAME Supported validator for canonical lifecycle phases only.
        % Optional ERROR_ID lets emit-path callers preserve their specific
        % failure identifier without a second wrapper surface.

            if nargin < 2 || isempty(error_id)
                error_id = 'CerUPP:InvalidWarningPhaseTag';
            end
            phase_name = run_warn_state_utils.resolve_phase_name_local( ...
                phase_tag, false, ...
                char(string(error_id)), ...
                'phase_tag must be a char vector or string scalar; got %s.', ...
                'Unknown warning phase tag "%s".');
        end

    end

    methods (Static, Access = private)
        function [run_warn_state, summary_scan] = scan_summary_content_local(run_warn_state)
        % SCAN_SUMMARY_CONTENT_LOCAL Build one compact summary snapshot for emit/preflight callers.

            summary_scan = struct( ...
                'has_content', false, ...
                'isosurface_skip_has_content', false, ...
                'io_has_content', false, ...
                'phase_entries', struct('name', {}, 'state', {}, 'event_count', {}, 'has_content', {}), ...
                'io_records', []);
            if nargin < 1 || ~isstruct(run_warn_state) || isempty(fieldnames(run_warn_state))
                return;
            end
            run_warn_state = run_warn_state_utils.normalize_run_warn_state_local(run_warn_state);
            if isfield(run_warn_state, 'warning_phase') && isstruct(run_warn_state.warning_phase)
                phase_names = run_warn_state_utils.canonical_phase_names();
                for ii = 1:numel(phase_names)
                    phase_field = run_warn_state_utils.resolve_phase_field(run_warn_state, phase_names{ii});
                    if isempty(phase_field) || ~isfield(run_warn_state.warning_phase, phase_field)
                        continue;
                    end
                    phase_entry = run_warn_state_utils.phase_summary_entry_local( ...
                        phase_names{ii}, run_warn_state.warning_phase.(phase_field));
                    if strcmp(phase_names{ii}, 'end') && ...
                            (run_warn_state_utils.state_value(phase_entry.state, 'isosurface_skipped_count', 0, 'num') > 0)
                        summary_scan.isosurface_skip_has_content = true;
                        summary_scan.has_content = true;
                    end
                    if ~phase_entry.has_content
                        continue;
                    end
                    summary_scan.phase_entries(end+1) = phase_entry; %#ok<AGROW>
                    summary_scan.has_content = true;
                end
            end
            if isfield(run_warn_state, 'output_io') && isstruct(run_warn_state.output_io)
                io_records = output_io_warn_utils.records_with_summary_content(run_warn_state.output_io);
                if ~isempty(io_records)
                    summary_scan.io_has_content = true;
                    summary_scan.io_records = io_records;
                    summary_scan.has_content = true;
                end
            end
        end

        function phase_entry = phase_summary_entry_local(phase_name, phase_state)
        % PHASE_SUMMARY_ENTRY_LOCAL Shared phase-summary scanner used by emit/preflight callers.

            if nargin < 1 || isempty(phase_name)
                phase_name = 'end';
            end
            phase_entry = struct( ...
                'name', char(string(phase_name)), ...
                'state', phase_state, ...
                'event_count', 0, ...
                'has_content', false);
            if nargin < 2 || ~isstruct(phase_state)
                return;
            end
            phase_state = run_warn_state_utils.require_phase_summary_record_local( ...
                phase_name, phase_state);
            phase_entry.state = phase_state;
            event_count = phase_state.total_event_count;
            phase_entry.event_count = event_count;
            phase_entry.has_content = (event_count > 0);
        end

        function emit_output_io_summary_record_local(rec, source_tag)
        % Emit one output-I/O summary line from a stored summary-ready record.

            if nargin < 2 || isempty(source_tag)
                source_tag = 'run_end';
            end
            last_phase = run_warn_state_utils.canonical_phase_name( ...
                rec.last_phase, 'CerUPP:InvalidOutputIOPhaseTag');
            if strcmp(rec.tag, 'nonfinite_diagnostic_log')
                run_warn_state_utils.emit_summary_info( ...
                    last_phase, 'nonfinite_summary', ...
                    source_tag, run_warn_state_utils.phase_softwarn_descriptor(last_phase), ...
                    '%s', run_warn_state_utils.compact_summary_text(rec.last_message, 160));
                return;
            end
            if strcmp(rec.tag, 'naninfo_log_write_failed')
                run_warn_state_utils.emit_summary_info( ...
                    last_phase, 'nonfinite_summary_write_failed', ...
                    source_tag, run_warn_state_utils.phase_softwarn_descriptor(last_phase), ...
                    'Could not write diagnostic_naninfo.txt: %s', ...
                    run_warn_state_utils.compact_summary_text(rec.last_message, 160));
                return;
            end
            [recent_phase_csv, recent_id_csv] = run_warn_state_utils.output_io_recent_summary_local(rec);
            run_warn_state_utils.emit_summary_info(last_phase, 'output_io_failure_summary', ...
                source_tag, ...
                run_warn_state_utils.phase_output_io_descriptor_local(last_phase), ...
                ['output-io tag=%s failures=%d (first_phase=%s, last_phase=%s, ', ...
                 'last_error_id=%s, recent_phases=%s, recent_error_ids=%s, ', ...
                 'first_path=%s, last_path=%s, last_message=%s).'], ...
                run_warn_state_utils.compact_summary_text(rec.tag, 64), ...
                rec.count, ...
                run_warn_state_utils.canonical_phase_name( ...
                    rec.first_phase, 'CerUPP:InvalidOutputIOPhaseTag'), ...
                last_phase, ...
                run_warn_state_utils.compact_summary_text(rec.last_error_id, 96), ...
                run_warn_state_utils.compact_summary_text(recent_phase_csv, 64), ...
                run_warn_state_utils.compact_summary_text(recent_id_csv, 120), ...
                run_warn_state_utils.compact_summary_path(rec.first_path, 120), ...
                run_warn_state_utils.compact_summary_path(rec.last_path, 120), ...
                run_warn_state_utils.compact_summary_text(rec.last_message, 160));
        end

        function phase_desc = phase_output_io_descriptor_local(phase_tag)
        % Human-readable category label for output-I/O summaries.

            phase_name = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidOutputIOPhaseTag');
            switch phase_name
                case 'setup'
                    phase_desc = 'setup output-io';
                case 'propagation'
                    phase_desc = 'propagation output-io';
                otherwise
                    phase_desc = 'end-stage output-io';
            end
        end

        function [recent_phase_csv, recent_id_csv] = output_io_recent_summary_local(rec)
        % Summarize bounded retained output-I/O history for the end-of-run summary.

            recent_phase_csv = run_warn_state_utils.canonical_phase_name( ...
                rec.last_phase, 'CerUPP:InvalidOutputIOPhaseTag');
            recent_id_csv = rec.last_error_id;
            if ~isstruct(rec) || ~isfield(rec, 'history') || ~isstruct(rec.history) || isempty(rec.history)
                return;
            end
            phase_tokens = {};
            id_tokens = {};
            for ii = 1:numel(rec.history)
                hist_event = rec.history(ii);
                phase_tokens{end+1} = run_warn_state_utils.canonical_phase_name( ... %#ok<AGROW>
                    hist_event.phase_tag, 'CerUPP:InvalidOutputIOPhaseTag');
                id_tokens{end+1} = hist_event.error_id; %#ok<AGROW>
            end
            recent_phase_csv = strjoin(run_warn_state_utils.unique_text_tokens_local(phase_tokens), ',');
            recent_id_csv = strjoin(run_warn_state_utils.unique_text_tokens_local(id_tokens), ',');
        end

        function tokens_out = unique_text_tokens_local(tokens_in)
        % Keep one stable unique list of nonempty text tokens.

            tokens_out = {};
            if nargin < 1 || isempty(tokens_in)
                return;
            end
            seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');
            for ii = 1:numel(tokens_in)
                token = char(string(tokens_in{ii}));
                token = strtrim(token);
                if isempty(token) || isKey(seen, token)
                    continue;
                end
                seen(token) = true;
                tokens_out{end+1} = token; %#ok<AGROW>
            end
        end

        function emit_phase_warning_summary_local(source_tag, phase_name, phase_state)
        % EMIT_PHASE_WARNING_SUMMARY_LOCAL Shared fixed-schema formatter for phase warning summaries.
        % Emits the canonical phase-bucket descriptor plus event counts,
        % first/last warning IDs, last warning message, and the
        % last-message format-failure state.

            phase_state = run_warn_state_utils.require_phase_summary_record_local( ...
                phase_name, phase_state);
            phase_desc = run_warn_state_utils.phase_softwarn_descriptor(phase_name);
            first_id = phase_state.first_id;
            if isempty(first_id)
                first_id = 'n/a';
            end
            first_id = run_warn_state_utils.compact_summary_text(first_id, 96);
            last_id = phase_state.last_id;
            if isempty(last_id)
                last_id = 'n/a';
            end
            last_id = run_warn_state_utils.compact_summary_text(last_id, 96);
            last_msg = phase_state.last_message;
            if isempty(last_msg)
                last_msg = 'n/a';
            end
            last_msg = run_warn_state_utils.compact_summary_text(last_msg, 160);
            event_count = phase_state.total_event_count;
            warn_once_emit_count = phase_state.warn_once_emit_count;
            softwarn_occurrence_count = phase_state.softwarn_occurrence_count;
            direct_record_count = phase_state.direct_record_count;
            format_failed_count = phase_state.format_failed_count;
            last_message_format_failed = phase_state.last_message_format_failed;
            run_warn_state_utils.emit_summary_info(phase_name, 'phase_warning_summary', ...
                source_tag, phase_desc, ...
                ['phase=%s phase-events=%d (warn_once=%d, soft=%d, direct=%d, ', ...
                 'format_failures=%d, first_id=%s, last_id=%s, last_message=%s, ', ...
                 'last_message_format_failed=%d).'], ...
                phase_name, event_count, ...
                warn_once_emit_count, softwarn_occurrence_count, direct_record_count, ...
                format_failed_count, first_id, last_id, last_msg, double(last_message_format_failed));
        end

        function phase_desc = phase_softwarn_descriptor(phase_tag)
        % PHASE_SOFTWARN_DESCRIPTOR Human-readable category label for warning summaries.

            phase_name = run_warn_state_utils.canonical_phase_name(phase_tag);
            switch phase_name
                case 'setup'
                    phase_desc = 'setup soft warn';
                case 'propagation'
                    phase_desc = 'propagation soft warn';
                case 'end'
                    phase_desc = 'end-stage soft warn';
            end
        end

        function phase_field = resolve_phase_field(run_warn_state, phase_tag)
        % RESOLVE_PHASE_FIELD Resolve a canonical phase into an existing state field.
        % Returns '' when warning_phase state is absent/malformed or when
        % the requested canonical phase bucket does not exist.

            phase_field = '';
            if nargin < 1 || ~isstruct(run_warn_state) || ...
               ~isfield(run_warn_state, 'warning_phase') || ...
               ~isstruct(run_warn_state.warning_phase)
                return;
            end
            phase_name = run_warn_state_utils.canonical_phase_name(phase_tag);
            if isfield(run_warn_state.warning_phase, phase_name)
                phase_field = phase_name;
            end
        end

        function phase_names = canonical_phase_names()
        % CANONICAL_PHASE_NAMES Fixed warning-phase summary ordering.

            phase_names = {'setup', 'propagation', 'end'};
        end

        function phase_name = resolve_phase_name_local(phase_tag, allow_empty_unknown, error_id, invalid_type_msg, invalid_value_msg)
        % RESOLVE_PHASE_NAME_LOCAL Shared canonical phase resolver for public/internal lifecycle tags.

            phase_name = '';
            if nargin < 2 || isempty(allow_empty_unknown)
                allow_empty_unknown = true;
            end
            if nargin < 3 || isempty(error_id)
                error_id = 'CerUPP:InvalidWarningPhaseTag';
            end
            if nargin < 4 || isempty(invalid_type_msg)
                invalid_type_msg = 'phase_tag must be a char vector or string scalar; got %s.';
            end
            if nargin < 5 || isempty(invalid_value_msg)
                invalid_value_msg = 'Unknown warning phase tag "%s".';
            end
            if nargin < 1 || isempty(phase_tag)
                phase_tag = '';
            elseif isstring(phase_tag) && isscalar(phase_tag)
                phase_tag = char(phase_tag);
            elseif ~ischar(phase_tag)
                error(error_id, invalid_type_msg, class(phase_tag));
            end
            raw = lower(strtrim(phase_tag));
            if isempty(raw)
                if allow_empty_unknown
                    return;
                end
                error(error_id, 'Empty warning phase tag is not allowed. Use one of: %s.', ...
                    strjoin(run_warn_state_utils.canonical_phase_names(), ', '));
            end
            switch raw
                case {'setup', 'propagation', 'end'}
                    phase_name = raw;
                    return;
            end
            error(error_id, [invalid_value_msg ' Use one of: %s.'], ...
                raw, strjoin(run_warn_state_utils.canonical_phase_names(), ', '));
        end

        function event_kind = normalize_internal_event_kind_local(event_kind_in)
        % NORMALIZE_INTERNAL_EVENT_KIND_LOCAL Fast-path exact internal event-kind labels.

            if isstring(event_kind_in) && isscalar(event_kind_in)
                event_kind_in = char(event_kind_in);
            elseif ~ischar(event_kind_in)
                error('CerUPP:InvalidWarningPhaseEventKind', ...
                    'event_kind must be a char vector or string scalar; got %s.', class(event_kind_in));
            end
            event_kind_in = lower(strtrim(event_kind_in));
            switch event_kind_in
                case {'warn_once_emit', 'softwarn_occurrence', 'direct_record'}
                    event_kind = event_kind_in;
                otherwise
                    error('CerUPP:InvalidWarningPhaseEventKind', ...
                        'Unsupported warning phase event kind "%s".', event_kind_in);
            end
        end

        function run_warn_state = initialize_warning_phase_schema_local(run_warn_state)
        % INITIALIZE_WARNING_PHASE_SCHEMA_LOCAL Ensure the canonical warning_phase buckets exist.
        % This is the ordinary runtime initializer, not the legacy repair path.

            run_warn_state = run_warn_state_utils.normalize_run_warn_state_local(run_warn_state);
            if ~isfield(run_warn_state, 'warning_phase')
                run_warn_state.warning_phase = struct();
            elseif ~isstruct(run_warn_state.warning_phase) || ~isscalar(run_warn_state.warning_phase)
                error('CerUPP:InvalidWarningPhaseSchema', ...
                    'run_warn_state.warning_phase must be a scalar struct.');
            end
            phase_names = run_warn_state_utils.canonical_phase_names();
            unknown_phase_fields = setdiff(fieldnames(run_warn_state.warning_phase), phase_names);
            if ~isempty(unknown_phase_fields)
                error('CerUPP:InvalidWarningPhaseSchema', ...
                    ['warning_phase contains unsupported noncanonical phase field(s): %s. ' ...
                     'Use only: %s.'], ...
                    strjoin(sort(unknown_phase_fields), ', '), ...
                    strjoin(run_warn_state_utils.canonical_phase_names(), ', '));
            end
            for ii = 1:numel(phase_names)
                phase_name = phase_names{ii};
                if ~isfield(run_warn_state.warning_phase, phase_name)
                    run_warn_state.warning_phase.(phase_name) = ...
                        run_warn_state_utils.empty_warning_phase_record();
                elseif ~isstruct(run_warn_state.warning_phase.(phase_name)) || ...
                        ~isscalar(run_warn_state.warning_phase.(phase_name))
                    error('CerUPP:InvalidWarningPhaseSchema', ...
                        'warning_phase.%s must be a scalar struct.', phase_name);
                end
            end
        end

        function rec = empty_warning_phase_record()
        % EMPTY_WARNING_PHASE_RECORD Fixed schema for per-phase warning summaries.

            rec = struct( ...
                'total_event_count', 0, ...
                'warn_once_emit_count', 0, ...
                'softwarn_occurrence_count', 0, ...
                'direct_record_count', 0, ...
                'format_failed_count', 0, ...
                'isosurface_skipped_count', 0, ...
                'first_id', '', ...
                'last_id', '', ...
                'last_message', '', ...
                'isosurface_skipped_last_message', '', ...
                'last_message_format_failed', false);
        end

        function warning_phase = require_phase_summary_schema_local(warning_phase)
        % REQUIRE_PHASE_SUMMARY_SCHEMA_LOCAL Strict validator for live phase-summary emission.

            if ~(isstruct(warning_phase) && isscalar(warning_phase))
                error('CerUPP:InvalidWarningPhaseSummarySchema', ...
                    'warning_phase must be a scalar struct before emitting summaries.');
            end
            phase_names = run_warn_state_utils.canonical_phase_names();
            unknown_phase_fields = setdiff(fieldnames(warning_phase), phase_names);
            if ~isempty(unknown_phase_fields)
                error('CerUPP:InvalidWarningPhaseSummarySchema', ...
                    ['warning_phase contains unsupported noncanonical phase field(s): %s. ' ...
                     'Use only: %s.'], ...
                    strjoin(sort(unknown_phase_fields), ', '), ...
                    strjoin(run_warn_state_utils.canonical_phase_names(), ', '));
            end
            for ii = 1:numel(phase_names)
                phase_name = phase_names{ii};
                if ~isfield(warning_phase, phase_name)
                    error('CerUPP:InvalidWarningPhaseSummarySchema', ...
                        'warning_phase.%s is required before emitting summaries.', phase_name);
                end
                warning_phase.(phase_name) = run_warn_state_utils.require_phase_summary_record_local( ...
                    phase_name, warning_phase.(phase_name));
            end
        end

        function rec = require_phase_summary_record_local(phase_name, rec)
        % REQUIRE_PHASE_SUMMARY_RECORD_LOCAL Strict validator for one canonical phase-summary record.

            if nargin < 1 || isempty(phase_name)
                phase_name = 'unknown';
            end
            if ~(isstruct(rec) && isscalar(rec))
                error('CerUPP:InvalidWarningPhaseSummarySchema', ...
                    'warning_phase.%s must be a scalar struct.', phase_name);
            end
            rec = struct( ...
                'total_event_count', run_warn_state_utils.require_state_value_local(rec, 'total_event_count', 'num'), ...
                'warn_once_emit_count', run_warn_state_utils.require_state_value_local(rec, 'warn_once_emit_count', 'num'), ...
                'softwarn_occurrence_count', run_warn_state_utils.require_state_value_local(rec, 'softwarn_occurrence_count', 'num'), ...
                'direct_record_count', run_warn_state_utils.require_state_value_local(rec, 'direct_record_count', 'num'), ...
                'format_failed_count', run_warn_state_utils.require_state_value_local(rec, 'format_failed_count', 'num'), ...
                'isosurface_skipped_count', run_warn_state_utils.require_state_value_local(rec, 'isosurface_skipped_count', 'num'), ...
                'first_id', run_warn_state_utils.require_state_value_local(rec, 'first_id', 'text'), ...
                'last_id', run_warn_state_utils.require_state_value_local(rec, 'last_id', 'text'), ...
                'last_message', run_warn_state_utils.require_state_value_local(rec, 'last_message', 'text'), ...
                'isosurface_skipped_last_message', run_warn_state_utils.require_state_value_local(rec, 'isosurface_skipped_last_message', 'text'), ...
                'last_message_format_failed', run_warn_state_utils.require_state_value_local(rec, 'last_message_format_failed', 'bool'));
            min_total = rec.warn_once_emit_count + rec.softwarn_occurrence_count + rec.direct_record_count;
            if rec.total_event_count < min_total
                error('CerUPP:InvalidWarningPhaseSummarySchema', ...
                    ['warning_phase.%s.total_event_count (%g) cannot be smaller than the ', ...
                     'sum of warn_once/softwarn/direct counts (%g).'], ...
                    phase_name, rec.total_event_count, min_total);
            end
            if rec.format_failed_count > rec.total_event_count
                error('CerUPP:InvalidWarningPhaseSummarySchema', ...
                    ['warning_phase.%s.format_failed_count (%g) cannot exceed ', ...
                     'total_event_count (%g).'], ...
                    phase_name, rec.format_failed_count, rec.total_event_count);
            end
        end

        function v = require_state_value_local(s, field_name, field_kind)
        % REQUIRE_STATE_VALUE_LOCAL Strict warning-summary accessor that errors on missing fields.

            if nargin < 3 || isempty(field_kind)
                field_kind = 'num';
            end
            if ~(isstruct(s) && isscalar(s))
                error('CerUPP:InvalidWarningStateCarrier', ...
                    'Expected a scalar struct carrier when reading strict %s field "%s".', field_kind, field_name);
            end
            if ~isfield(s, field_name)
                error('CerUPP:InvalidWarningPhaseSummarySchema', ...
                    'Missing required warning-summary field "%s".', field_name);
            end
            raw = s.(field_name);
            v = run_warn_state_utils.normalize_state_value_local(raw, field_name, field_kind);
        end

        function v = normalize_state_value_local(raw, field_name, field_kind)
        % NORMALIZE_STATE_VALUE_LOCAL Coerce one warning-summary field to the requested scalar type.

            switch field_kind
                case 'num'
                    if ~(isnumeric(raw) || islogical(raw))
                        error('CerUPP:InvalidWarningStateField', ...
                            'Field "%s" must be numeric/logical scalar.', field_name);
                    end
                    v = double(raw);
                    if ~isscalar(v) || ~isfinite(v)
                        error('CerUPP:InvalidWarningStateField', ...
                            'Field "%s" must be a finite scalar.', field_name);
                    end
                case 'text'
                    if ischar(raw)
                        v = raw;
                    elseif isstring(raw) && isscalar(raw)
                        v = char(raw);
                    else
                        error('CerUPP:InvalidWarningStateField', ...
                            'Field "%s" must be char or scalar string.', field_name);
                    end
                case 'bool'
                    v = struct_utils.normalize_bool_scalar( ...
                        raw, field_name, 'CerUPP:InvalidWarningStateField');
                otherwise
                    error('CerUPP:InvalidWarningStateAccessorKind', ...
                        'Unsupported warning-state accessor kind "%s".', field_kind);
            end
        end

        function v = normalize_optional_state_value_local(raw, field_name, field_kind)
        % NORMALIZE_OPTIONAL_STATE_VALUE_LOCAL Coerce optional warning-summary fields and keep scalar sentinels.

            switch field_kind
                case 'num'
                    if ~(isnumeric(raw) || islogical(raw))
                        error('CerUPP:InvalidWarningStateField', ...
                            'Field "%s" must be numeric/logical scalar.', field_name);
                    end
                    v = double(raw);
                    if ~isscalar(v)
                        error('CerUPP:InvalidWarningStateField', ...
                            'Field "%s" must be a scalar.', field_name);
                    end
                case 'text'
                    if ischar(raw)
                        v = raw;
                    elseif isstring(raw) && isscalar(raw)
                        v = char(raw);
                    else
                        error('CerUPP:InvalidWarningStateField', ...
                            'Field "%s" must be char or scalar string.', field_name);
                    end
                case 'bool'
                    v = struct_utils.normalize_bool_scalar( ...
                        raw, field_name, 'CerUPP:InvalidWarningStateField');
                otherwise
                    error('CerUPP:InvalidWarningStateAccessorKind', ...
                        'Unsupported warning-state accessor kind "%s".', field_kind);
            end
        end

        function run_warn_state = normalize_run_warn_state_local(run_warn_state)
        % NORMALIZE_RUN_WARN_STATE_LOCAL Shared empty/type normalization for internal entry points.

            if nargin < 1 || isempty(run_warn_state)
                run_warn_state = struct();
            elseif ~isstruct(run_warn_state)
                error('CerUPP:InvalidRunWarnState', ...
                    'run_warn_state must be a struct; got %s.', class(run_warn_state));
            end
            run_warn_state = struct_utils.ensure_warned_keys_map(run_warn_state);
        end

        function soft_warn_state = normalize_soft_warn_state_local(soft_warn_state, bucket_name)
        % NORMALIZE_SOFT_WARN_STATE_LOCAL Shared empty/type normalization for subsystem warning maps.

            if nargin < 1 || isempty(soft_warn_state)
                soft_warn_state = struct();
            elseif ~isstruct(soft_warn_state)
                error('CerUPP:InvalidRunWarnState', ...
                    'soft warning state must be a struct; got %s.', class(soft_warn_state));
            end
            soft_warn_state = struct_utils.ensure_warned_keys_map(soft_warn_state);
            if nargin >= 2 && ~isempty(bucket_name)
                bucket_name = run_warn_state_utils.normalize_bucket_name_local(bucket_name);
                if isfield(soft_warn_state, 'warning_bucket_name') && ...
                        ~isempty(soft_warn_state.warning_bucket_name)
                    stored_bucket_name = run_warn_state_utils.normalize_bucket_name_local( ...
                        soft_warn_state.warning_bucket_name);
                    if ~strcmp(stored_bucket_name, bucket_name)
                        error('CerUPP:WarningBucketOwnershipMismatch', ...
                            ['Warning bucket state is tagged as ''%s'', but the caller requested ', ...
                             'bucket ''%s''.'], ...
                            stored_bucket_name, bucket_name);
                    end
                end
                soft_warn_state.warning_bucket_name = bucket_name;
            end
        end

        function run_warn_state = clear_emitted_summary_ledgers_local(run_warn_state)
        % CLEAR_EMITTED_SUMMARY_LEDGERS_LOCAL Reset emitted run-summary buckets without dropping outer state.

            run_warn_state = run_warn_state_utils.normalize_run_warn_state_local(run_warn_state);

            if isfield(run_warn_state, 'warning_phase') && isstruct(run_warn_state.warning_phase)
                phase_names = run_warn_state_utils.canonical_phase_names();
                for ii = 1:numel(phase_names)
                    run_warn_state.warning_phase.(phase_names{ii}) = ...
                        run_warn_state_utils.empty_warning_phase_record();
                end
            end

            if isfield(run_warn_state, 'output_io') && isstruct(run_warn_state.output_io)
                run_warn_state.output_io = output_io_warn_utils.empty_output_io_state();
            end
        end

        function tf = is_isosurface_skip_warning_id_local(warn_id)
        % IS_ISOSURFACE_SKIP_WARNING_ID_LOCAL True for the fixed isosurface-skip warning IDs.

            tf = strcmp(warn_id, 'CerUPP:Plot:IsosurfaceSkipped') || ...
                 strcmp(warn_id, 'CerUPP:Plot:IsosurfaceSkippedInvalidMax');
        end

        function rec = accumulate_isosurface_skip_summary_local(rec, count_add, last_msg)
        % ACCUMULATE_ISOSURFACE_SKIP_SUMMARY_LOCAL Fold isosurface-skip summary state into warning_phase.end.

            if ~(isstruct(rec) && isscalar(rec))
                rec = run_warn_state_utils.empty_warning_phase_record();
            end
            if nargin < 2 || isempty(count_add)
                count_add = 0;
            end
            if nargin < 3 || isempty(last_msg)
                last_msg = '';
            end
            rec.isosurface_skipped_count = run_warn_state_utils.state_value( ...
                rec, 'isosurface_skipped_count', 0, 'num') + double(count_add);
            if ~isempty(last_msg)
                rec.isosurface_skipped_last_message = ...
                    run_warn_state_utils.sanitize_warn_message_text(last_msg);
            elseif ~isfield(rec, 'isosurface_skipped_last_message')
                rec.isosurface_skipped_last_message = '';
            end
        end
    end
end
