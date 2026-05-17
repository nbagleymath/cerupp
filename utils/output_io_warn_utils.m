classdef output_io_warn_utils
%OUTPUT_IO_WARN_UTILS Canonical owner for output-I/O warning/accounting records.
% Purpose:
% - Record output-I/O failures/info events without cluttering the main driver,
%   checkpoint path, and plotting code with repeated warning accounting.
% - Normalize and summarize the shared output-I/O ledger used at end of run.
% Called mainly from checkpoint_utils.m, plot_utils.m, and cerupp_section6a_postprocess.m.

    methods (Static, Hidden)
        function run_warn_state = record_output_io_failure( ...
                run_warn_state, tag, io_path, me_in, phase_tag)
        %RECORD_OUTPUT_IO_FAILURE Append one output/checkpoint failure record.
        %   Under the matching output_io tag this initializes first_path
        %   and first_phase on the first hit, then updates the count,
        %   last path/phase/error, and bounded history on later hits.
        %   ME_IN may be an MException, a scalar struct-like payload with
        %   identifier/message fields, or an empty placeholder, in which
        %   case the helper records the generic failure pair.

            run_warn_state = output_io_warn_utils.require_run_warn_state_local(run_warn_state);
            if nargin < 2 || isempty(tag)
                tag = 'output_io_failure';
            end
            if nargin < 3 || isempty(io_path)
                io_path = '';
            end
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidEmitWarningPhaseTag');
            err_id = 'CerUPP:OutputIO:Failure';
            err_msg = '(no message)';
            if isa(me_in, 'MException')
                if ~isempty(me_in.identifier), err_id = me_in.identifier; end
                if ~isempty(me_in.message), err_msg = me_in.message; end
            elseif isstruct(me_in)
                if isfield(me_in, 'identifier') && ~isempty(me_in.identifier), err_id = me_in.identifier; end
                if isfield(me_in, 'message') && ~isempty(me_in.message), err_msg = me_in.message; end
            end
            output_io_state = output_io_warn_utils.normalize_output_io_state( ...
                struct_utils.opt_struct_field(run_warn_state, 'output_io', struct()));
            output_io_state = output_io_warn_utils.update_output_io_record_local( ...
                output_io_state, tag, io_path, phase_tag, err_id, err_msg);
            run_warn_state.output_io = output_io_state;
        end

        function run_warn_state = record_output_io_info( ...
                run_warn_state, tag, io_path, info_id, info_msg, phase_tag)
        %RECORD_OUTPUT_IO_INFO Append one output/diagnostic info record to the shared output_io ledger.

            run_warn_state = output_io_warn_utils.require_run_warn_state_local(run_warn_state);
            if nargin < 2 || isempty(tag)
                tag = 'output_io';
            end
            if nargin < 3 || isempty(io_path)
                io_path = '';
            end
            if nargin < 4 || isempty(info_id)
                info_id = 'CerUPP:OutputIO:Info';
            end
            if nargin < 5 || isempty(info_msg)
                info_msg = '(no message)';
            end
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidEmitWarningPhaseTag');
            output_io_state = output_io_warn_utils.normalize_output_io_state( ...
                struct_utils.opt_struct_field(run_warn_state, 'output_io', struct()));
            output_io_state = output_io_warn_utils.update_output_io_record_local( ...
                output_io_state, tag, io_path, phase_tag, char(string(info_id)), info_msg);
            run_warn_state.output_io = output_io_state;
        end

        function output_io_state = empty_output_io_state()
        % EMPTY_OUTPUT_IO_STATE Return an empty output-I/O ledger struct.

            output_io_state = struct( ...
                'history_limit', output_io_warn_utils.default_output_io_history_limit_local(), ...
                'records', repmat(output_io_warn_utils.empty_output_io_record_local(''), 0, 1));
        end

        function output_io_state = normalize_output_io_state(output_io_state)
        % NORMALIZE_OUTPUT_IO_STATE Fill defaults, bound history, canonicalize
        % records, merge duplicate tags, sort the canonical record list, and
        % preserve normalization notes in stored messages when needed.

            if nargin < 1 || isempty(output_io_state) || ~isstruct(output_io_state)
                output_io_state = output_io_warn_utils.empty_output_io_state();
                return;
            end

            history_limit = output_io_warn_utils.default_output_io_history_limit_local();
            if isfield(output_io_state, 'history_limit') && ...
                    isnumeric(output_io_state.history_limit) && ...
                    isscalar(output_io_state.history_limit) && ...
                    isfinite(output_io_state.history_limit) && ...
                    (output_io_state.history_limit >= 1)
                history_limit = floor(double(output_io_state.history_limit));
            end

            records_in = output_io_warn_utils.empty_output_io_state().records;
            if isfield(output_io_state, 'records')
                records_in = output_io_state.records;
            end

            output_io_state = struct( ...
                'history_limit', history_limit, ...
                'records', output_io_warn_utils.normalize_output_io_records_local(records_in, history_limit));
        end

        function run_warn_state = handle_png_export_status( ...
                run_warn_state, status, output_path, phase_tag, ...
                failure_warn_key, failure_warn_id, record_failure_tag, emit_warning)
        %HANDLE_PNG_EXPORT_STATUS Process one PNG export attempt result.
        %   STATUS is the struct returned by the plot_support_utils PNG
        %   fallback helper. Successful exportgraphics fallbacks may emit a
        %   one-time warning and then return. Failed exports may emit a
        %   one-time warning and, when RECORD_FAILURE_TAG is nonempty,
        %   append a failure record to run_warn_state.output_io. Failure
        %   accounting stays attached to run_warn_state even when
        %   EMIT_WARNING=false.
        %   Optional inputs default to PHASE_TAG='end',
        %   FAILURE_WARN_KEY='png_export_failed',
        %   FAILURE_WARN_ID='CerUPP:Plot:ExportGraphicsFailed',
        %   RECORD_FAILURE_TAG='' (skip output_io recording), and
        %   EMIT_WARNING=true.

            run_warn_state = output_io_warn_utils.require_run_warn_state_local(run_warn_state);
            status_ok = true;
            status_reason = '';
            export_err = '';
            print_err = '';
            invalid_status_detail = '';
            if nargin < 2 || ~isstruct(status)
                status_ok = false;
                status_reason = 'invalid_status_payload';
                invalid_status_detail = 'missing or nonstruct PNG export status payload';
                status = struct();
            else
                if isfield(status, 'reason') && ~isempty(status.reason)
                    status_reason = char(string(status.reason));
                end
                if isfield(status, 'export_error_message') && ~isempty(status.export_error_message)
                    export_err = char(string(status.export_error_message));
                end
                if isfield(status, 'print_error_message') && ~isempty(status.print_error_message)
                    print_err = char(string(status.print_error_message));
                end
                if isfield(status, 'ok') && ~isempty(status.ok)
                    try
                        status_ok = struct_utils.normalize_bool_scalar( ...
                            status.ok, 'png export status.ok', 'CerUPP:Plot:InvalidPngExportStatus');
                    catch me_status
                        status_ok = false;
                        invalid_status_detail = me_status.message;
                    end
                else
                    status_ok = false;
                    invalid_status_detail = 'PNG export status payload is missing required ok field.';
                end
                if ~status_ok && isempty(status_reason)
                    status_reason = 'invalid_status_payload';
                end
            end
            if ~isempty(invalid_status_detail)
                if isempty(print_err)
                    print_err = invalid_status_detail;
                else
                    print_err = sprintf('%s; %s', print_err, invalid_status_detail);
                end
            end
            if status_ok && ~strcmp(status_reason, 'missing_exportgraphics') && ...
                    ~strcmp(status_reason, 'exportgraphics_failed')
                return;
            end

            if nargin < 3 || isempty(output_path)
                output_path = '';
            end
            if nargin < 4 || isempty(phase_tag)
                phase_tag = 'end';
            end
            if nargin < 5 || isempty(failure_warn_key)
                failure_warn_key = 'png_export_failed';
            end
            if nargin < 6 || isempty(failure_warn_id)
                failure_warn_id = 'CerUPP:Plot:ExportGraphicsFailed';
            end
            if nargin < 7
                record_failure_tag = '';
            end
            if nargin < 8 || isempty(emit_warning)
                emit_warning = true;
            end

            if emit_warning && status_ok && strcmp(status_reason, 'missing_exportgraphics')
                run_warn_state = output_io_warn_utils.emit_output_io_warn_once( ...
                    run_warn_state, ...
                    phase_tag, ...
                    'exportgraphics_print_fallback', ...
                    'CerUPP:OutputIO:ExportGraphicsFallbackPrint', ...
                    ['save_outputs_as_png=true but exportgraphics is unavailable on this MATLAB release; ', ...
                     'using print(...) fallback (first file: %s).'], ...
                    char(output_path));
            elseif emit_warning && status_ok && strcmp(status_reason, 'exportgraphics_failed')
                run_warn_state = output_io_warn_utils.emit_output_io_warn_once( ...
                    run_warn_state, ...
                    phase_tag, ...
                    'exportgraphics_runtime_fallback', ...
                    'CerUPP:OutputIO:ExportGraphicsRuntimeFallbackPrint', ...
                    ['exportgraphics(...) failed; falling back to print(...). ', ...
                     'First file: %s. exportgraphics error: %s'], ...
                    char(output_path), export_err);
            end
            if status_ok
                return;
            end

            if ~isempty(record_failure_tag)
                [record_error_id, record_error_message] = ...
                    output_io_warn_utils.png_export_failure_record_local( ...
                    status_reason, export_err, print_err);
                me_io = struct( ...
                    'identifier', record_error_id, ...
                    'message', record_error_message);
                run_warn_state = output_io_warn_utils.record_output_io_failure( ...
                    run_warn_state, record_failure_tag, char(output_path), me_io, phase_tag);
            end

            failure_msg = output_io_warn_utils.png_export_failure_warning_message_local( ...
                status_reason, output_path, export_err, print_err);
            if ~emit_warning
                return;
            end

            run_warn_state = output_io_warn_utils.emit_output_io_warn_once( ...
                run_warn_state, ...
                phase_tag, ...
                char(string(failure_warn_key)), char(string(failure_warn_id)), ...
                '%s', failure_msg);
        end

    end

    methods (Static, Hidden)
        % Supported cross-module internal output-I/O summary API.

        function records = records_with_summary_content(output_io_state)
        % RECORDS_WITH_SUMMARY_CONTENT Canonical nonempty output-I/O records for summary emission.

            records = output_io_warn_utils.summary_records_local(output_io_state);
        end

        function run_warn_state = emit_output_io_warn_once( ...
                run_warn_state, phase_tag, warn_key, canon_id, msg_fmt, varargin)
        % EMIT_OUTPUT_IO_WARN_ONCE Emit one output-I/O warn-once warning through
        % the shared phase-summary owner so deduplicated output/export/checkpoint
        % warnings increment the same phase ledger as the rest of the run.

            run_warn_state = output_io_warn_utils.require_run_warn_state_local(run_warn_state);
            if nargin < 2 || isempty(phase_tag)
                phase_tag = run_warn_state_utils.phase_end();
            end
            if nargin < 3 || isempty(warn_key)
                warn_key = 'output_io_warning';
            end
            if nargin < 4 || isempty(canon_id)
                canon_id = 'CerUPP:OutputIO:Warning';
            end
            if nargin < 5 || isempty(msg_fmt)
                msg_fmt = '%s';
            end
            run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                run_warn_state, ...
                phase_tag, ...
                char(string(warn_key)), char(string(canon_id)), char(string(msg_fmt)), varargin{:});
        end

    end

    methods (Static, Access = private)
        function records = summary_records_local(output_io_state)
        % SUMMARY_RECORDS_LOCAL Canonical nonempty records for summary emission.

            output_io_state = output_io_warn_utils.normalize_output_io_state(output_io_state);
            records = output_io_state.records;
            if isempty(records)
                return;
            end
            keep_mask = ([records.count] > 0);
            records = records(keep_mask);
        end

        function output_io_state = update_output_io_record_local( ...
                output_io_state, tag, io_path, phase_tag, err_id, err_msg)
        % UPDATE_OUTPUT_IO_RECORD_LOCAL Canonical append/update path for one output-I/O tag.

            tag_value = output_io_warn_utils.resolve_output_io_tag_field_local(tag);
            io_path = char(string(io_path));
            phase_tag = char(string(phase_tag));
            err_id = char(string(err_id));
            err_msg = output_io_warn_utils.sanitize_output_io_message_local(err_msg);
            rec_idx = output_io_warn_utils.find_output_io_record_index_local( ...
                output_io_state.records, tag_value);
            if rec_idx == 0
                rec = output_io_warn_utils.empty_output_io_record_local(tag_value);
                rec.first_path = io_path;
                rec.last_path = io_path;
                rec.first_phase = phase_tag;
                rec.last_phase = phase_tag;
                rec.last_error_id = err_id;
                rec.last_message = err_msg;
                output_io_state.records(end+1, 1) = rec;
                rec_idx = numel(output_io_state.records);
            end

            rec = output_io_state.records(rec_idx);
            rec.count = output_io_warn_utils.increment_output_io_count_local(rec);
            rec.last_path = io_path;
            rec.last_phase = phase_tag;
            rec.last_error_id = err_id;
            rec.last_message = err_msg;
            rec.history = output_io_warn_utils.append_output_io_history_local( ...
                rec.history, output_io_warn_utils.build_output_io_history_event_local( ...
                phase_tag, io_path, err_id, err_msg), ...
                output_io_state.history_limit);
            output_io_state.records(rec_idx) = rec;
        end

        function count_out = increment_output_io_count_local(rec)
        % INCREMENT_OUTPUT_IO_COUNT_LOCAL Robust scalar count increment for one record.

            count_out = 1;
            if isfield(rec, 'count') && isnumeric(rec.count) && isscalar(rec.count) && isfinite(rec.count)
                count_out = double(rec.count) + 1;
            end
        end

        function msg_out = sanitize_output_io_message_local(msg_in)
        % SANITIZE_OUTPUT_IO_MESSAGE_LOCAL Collapse CR/LF-heavy messages to one line.

            msg_out = char(string(msg_in));
            msg_out = strrep(msg_out, sprintf('\n'), ' ');
            msg_out = strrep(msg_out, sprintf('\r'), ' ');
        end

        function tag_names = canonical_output_io_tags()
        % CANONICAL_OUTPUT_IO_TAGS Internal fixed output-I/O tag vocabulary.

            tag_names = { ...
                'beam_metrics_snapshot', ...
                'a_s_rho_snapshot_checkpoint', ...
                'current_run_pointer', ...
                'current_run_pointer_delete', ...
                'debug_csv_export', ...
                'end_snapshot_save', ...
                'fig_export', ...
                'filament_info_csv', ...
                'final_full_save', ...
                'final_fullsave_build_failed', ...
                'final_restart_checkpoint', ...
                'intermediate_checkpoint', ...
                'intermediate_checkpoint_fullsave', ...
                'latest_fully_packaged_run_pointer', ...
                'latest_propagation_complete_run_pointer', ...
                'latest_successful_run_pointer', ...
                'naninfo_log_write_failed', ...
                'nonfinite_diagnostic_log', ...
                'output_io', ...
                'output_io_failure', ...
                'output_io_invalid_record', ...
                'png_export', ...
                'plot_output_dir_create', ...
                'reassembled_diag_save', ...
                'reassembled_plot_export', ...
                'run_status_failure_write', ...
                'run_status_final_write', ...
                'run_status_setup_write', ...
                'text_io', ...
                'timing_csv'};
        end

        function tag_field = resolve_output_io_tag_field_local(tag)
        % RESOLVE_OUTPUT_IO_TAG_FIELD_LOCAL Canonical output-I/O tag token validator.

            if nargin < 1 || isempty(tag)
                tag_field = 'output_io_failure';
                return;
            end
            if isstring(tag) && isscalar(tag)
                tag = char(tag);
            end
            if ~ischar(tag)
                error('CerUPP:InvalidOutputIOTag', ...
                    'output_io tag must be a char vector or scalar string; got %s.', class(tag));
            end
            tag_field = tag;
            if isempty(tag_field)
                tag_field = 'output_io_failure';
                return;
            end
            if isempty(regexp(tag_field, '^[A-Za-z][A-Za-z0-9_]*$', 'once'))
                error('CerUPP:InvalidOutputIOTag', ...
                    'output_io tag "%s" must already be a canonical MATLAB identifier.', tag_field);
            end
            tag_names = output_io_warn_utils.canonical_output_io_tags();
            if ~any(strcmp(tag_field, tag_names))
                error('CerUPP:InvalidOutputIOTag', ...
                    'Unsupported output_io tag "%s". Use one of: %s.', ...
                    tag_field, strjoin(tag_names, ', '));
            end
        end

        function run_warn_state = require_run_warn_state_local(run_warn_state)
        % REQUIRE_RUN_WARN_STATE_LOCAL Lightweight local struct guard for output-I/O accounting.

            if nargin < 1 || isempty(run_warn_state)
                run_warn_state = struct();
            elseif ~isstruct(run_warn_state) || ~isscalar(run_warn_state)
                error('CerUPP:InvalidRunWarnState', ...
                    'run_warn_state must be a scalar struct; got %s.', class(run_warn_state));
            end
        end

        function history_limit = default_output_io_history_limit_local()
        % DEFAULT_OUTPUT_IO_HISTORY_LIMIT_LOCAL Bound per-tag retained history.

            history_limit = 4;
        end

        function [err_id, err_msg] = png_export_failure_record_local(status_reason, export_err, print_err)
        % PNG_EXPORT_FAILURE_RECORD_LOCAL Preserve backend-specific PNG failure causes in output-IO records.

            if nargin < 1 || isempty(status_reason)
                status_reason = 'print_fallback_failed';
            end
            if nargin < 2 || isempty(export_err)
                export_err = '';
            end
            if nargin < 3 || isempty(print_err)
                print_err = '';
            end
            switch char(status_reason)
                case 'exportgraphics_failed'
                    err_id = 'CerUPP:Plot:ExportGraphicsThenPrintFailed';
                case 'missing_exportgraphics'
                    err_id = 'CerUPP:Plot:ExportGraphicsUnavailablePrintFailed';
                case 'invalid_status_payload'
                    err_id = 'CerUPP:Plot:InvalidPngExportStatus';
                otherwise
                    err_id = 'CerUPP:Plot:PrintFallbackPngFailed';
            end
            err_msg = sprintf('reason=%s; export_error=%s; print_error=%s', ...
                char(status_reason), char(export_err), char(print_err));
        end

        function rec = empty_output_io_record_local(tag)
        % EMPTY_OUTPUT_IO_RECORD_LOCAL Fixed per-tag output-I/O record schema.

            if nargin < 1 || isempty(tag)
                tag = '';
            end
            rec = struct( ...
                'count', 0, ...
                'tag', char(string(tag)), ...
                'first_path', '', ...
                'last_path', '', ...
                'first_phase', '', ...
                'last_phase', '', ...
                'last_error_id', '', ...
                'last_message', '', ...
                'history', repmat(output_io_warn_utils.empty_output_io_history_event_local(), 0, 1));
        end

        function hist_event = empty_output_io_history_event_local()
        % EMPTY_OUTPUT_IO_HISTORY_EVENT_LOCAL Fixed schema for one retained failure event.

            hist_event = struct( ...
                'phase_tag', '', ...
                'io_path', '', ...
                'error_id', '', ...
                'message', '');
        end

        function hist_event = build_output_io_history_event_local(phase_tag, io_path, err_id, err_msg)
        % BUILD_OUTPUT_IO_HISTORY_EVENT_LOCAL Normalize one retained failure event.

            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                phase_tag, 'CerUPP:InvalidEmitWarningPhaseTag');
            if nargin < 2 || isempty(io_path)
                io_path = '';
            end
            if nargin < 3 || isempty(err_id)
                err_id = 'CerUPP:OutputIO:Failure';
            end
            if nargin < 4 || isempty(err_msg)
                err_msg = '(no message)';
            end
            hist_event = output_io_warn_utils.empty_output_io_history_event_local();
            hist_event.phase_tag = char(string(phase_tag));
            hist_event.io_path = char(string(io_path));
            hist_event.error_id = char(string(err_id));
            hist_event.message = strrep(strrep(char(string(err_msg)), sprintf('\n'), ' '), sprintf('\r'), ' ');
        end

        function history = append_output_io_history_local(history_in, hist_event, history_limit)
        % APPEND_OUTPUT_IO_HISTORY_LOCAL Retain a bounded per-tag output-I/O history.

            history = output_io_warn_utils.normalize_output_io_history_local(history_in, history_limit);
            history(end+1, 1) = hist_event;
            if numel(history) > history_limit
                history = history((end - history_limit + 1):end);
            end
        end

        function history = normalize_output_io_history_local(history_in, history_limit)
        % NORMALIZE_OUTPUT_IO_HISTORY_LOCAL Sanitize retained failure history entries.

            if nargin < 2 || isempty(history_limit) || ~isfinite(history_limit)
                history_limit = output_io_warn_utils.default_output_io_history_limit_local();
            end
            history_limit = max(1, floor(double(history_limit)));
            history = repmat(output_io_warn_utils.empty_output_io_history_event_local(), 0, 1);
            if nargin < 1 || isempty(history_in) || ~isstruct(history_in)
                return;
            end
            for ii = 1:numel(history_in)
                hist_in = history_in(ii);
                hist_event = output_io_warn_utils.empty_output_io_history_event_local();
                [hist_event.phase_tag, phase_note] = ...
                    output_io_warn_utils.normalize_output_io_phase_local( ...
                        struct_utils.opt_struct_field(hist_in, 'phase_tag', ''), ...
                        'end', 'history.phase_tag');
                if isfield(hist_in, 'io_path') && ~isempty(hist_in.io_path)
                    hist_event.io_path = char(string(hist_in.io_path));
                end
                if isfield(hist_in, 'error_id') && ~isempty(hist_in.error_id)
                    hist_event.error_id = char(string(hist_in.error_id));
                end
                if isfield(hist_in, 'message') && ~isempty(hist_in.message)
                    hist_event.message = strrep(strrep(char(string(hist_in.message)), sprintf('\n'), ' '), sprintf('\r'), ' ');
                end
                if ~isempty(phase_note)
                    if isempty(hist_event.message)
                        hist_event.message = phase_note;
                    else
                        hist_event.message = sprintf('%s | %s', phase_note, hist_event.message);
                    end
                end
                history(end+1, 1) = hist_event; %#ok<AGROW>
            end
            if numel(history) > history_limit
                history = history((end - history_limit + 1):end);
            end
        end

        function records = normalize_output_io_records_local(records_in, history_limit)
        % NORMALIZE_OUTPUT_IO_RECORDS_LOCAL Sanitize fixed-schema output-I/O records.

            records = repmat(output_io_warn_utils.empty_output_io_record_local(''), 0, 1);
            if nargin < 1 || isempty(records_in) || ~isstruct(records_in)
                return;
            end
            for ii = 1:numel(records_in)
                rec_in = records_in(ii);
                rec = output_io_warn_utils.empty_output_io_record_local('output_io_invalid_record');
                [rec.tag, invalid_tag_message] = ...
                    output_io_warn_utils.normalize_output_io_record_tag_local(rec_in);
                [rec.count, invalid_count_message] = ...
                    output_io_warn_utils.normalize_output_io_record_count_local(rec_in);
                rec.first_path = run_warn_state_utils.state_value(rec_in, 'first_path', '', 'text');
                rec.last_path = run_warn_state_utils.state_value(rec_in, 'last_path', '', 'text');
                [rec.last_phase, invalid_last_phase_message] = ...
                    output_io_warn_utils.normalize_output_io_phase_local( ...
                        run_warn_state_utils.state_value(rec_in, 'last_phase', '', 'text'), ...
                        'end', 'last_phase');
                [rec.first_phase, invalid_first_phase_message] = ...
                    output_io_warn_utils.normalize_output_io_phase_local( ...
                        run_warn_state_utils.state_value(rec_in, 'first_phase', '', 'text'), ...
                        rec.last_phase, 'first_phase');
                rec.last_error_id = run_warn_state_utils.state_value(rec_in, 'last_error_id', '', 'text');
                rec.last_message = run_warn_state_utils.state_value(rec_in, 'last_message', '', 'text');
                if isfield(rec_in, 'history')
                    rec.history = output_io_warn_utils.normalize_output_io_history_local( ...
                        rec_in.history, history_limit);
                end
                rec.last_message = output_io_warn_utils.append_output_io_normalization_note_local( ...
                    rec.last_message, invalid_tag_message);
                rec.last_message = output_io_warn_utils.append_output_io_normalization_note_local( ...
                    rec.last_message, invalid_count_message);
                rec.last_message = output_io_warn_utils.append_output_io_normalization_note_local( ...
                    rec.last_message, invalid_first_phase_message);
                rec.last_message = output_io_warn_utils.append_output_io_normalization_note_local( ...
                    rec.last_message, invalid_last_phase_message);
                rec_idx = output_io_warn_utils.find_output_io_record_index_local(records, rec.tag);
                if rec_idx == 0
                    records(end+1, 1) = rec; %#ok<AGROW>
                else
                    records(rec_idx) = output_io_warn_utils.merge_output_io_records_local( ...
                        records(rec_idx), rec, history_limit);
                end
            end
            if numel(records) > 1
                [~, order] = sort({records.tag});
                records = records(order);
            end
        end

        function rec = merge_output_io_records_local(rec_older, rec_newer, history_limit)
        % MERGE_OUTPUT_IO_RECORDS_LOCAL Deduplicate canonical tags during normalization.

            if nargin < 3 || isempty(history_limit) || ~isfinite(history_limit)
                history_limit = output_io_warn_utils.default_output_io_history_limit_local();
            end
            history_limit = max(1, floor(double(history_limit)));
            rec = rec_older;
            rec.tag = output_io_warn_utils.resolve_output_io_tag_field_local(rec_older.tag);
            rec.count = double(rec_older.count) + double(rec_newer.count);
            if isempty(rec.first_path)
                rec.first_path = rec_newer.first_path;
            end
            if isempty(rec.first_phase)
                rec.first_phase = rec_newer.first_phase;
            end
            if ~isempty(rec_newer.last_path)
                rec.last_path = rec_newer.last_path;
            end
            if ~isempty(rec_newer.last_phase)
                rec.last_phase = rec_newer.last_phase;
            end
            if ~isempty(rec_newer.last_error_id)
                rec.last_error_id = rec_newer.last_error_id;
            end
            if ~isempty(rec_newer.last_message)
                rec.last_message = rec_newer.last_message;
            end
            merged_history = [ ...
                output_io_warn_utils.normalize_output_io_history_local(rec_older.history, history_limit); ...
                output_io_warn_utils.normalize_output_io_history_local(rec_newer.history, history_limit)];
            rec.history = output_io_warn_utils.normalize_output_io_history_local( ...
                merged_history, history_limit);
        end

        function [tag_field, invalid_tag_message] = normalize_output_io_record_tag_local(rec_in)
        % NORMALIZE_OUTPUT_IO_RECORD_TAG_LOCAL Keep malformed stored tags distinct from generic output failures.

            invalid_tag_message = '';
            tag_raw = run_warn_state_utils.state_value(rec_in, 'tag', '', 'text');
            if isempty(tag_raw)
                tag_field = 'output_io_invalid_record';
                invalid_tag_message = 'Normalized output_io record with missing/empty tag into output_io_invalid_record.';
                return;
            end
            try
                tag_field = output_io_warn_utils.resolve_output_io_tag_field_local(tag_raw);
            catch me_tag
                tag_field = 'output_io_invalid_record';
                invalid_tag_message = sprintf( ...
                    'Normalized output_io record with invalid tag "%s" into output_io_invalid_record (%s).', ...
                    tag_raw, me_tag.message);
            end
        end

        function rec_idx = find_output_io_record_index_local(records, tag)
        % FIND_OUTPUT_IO_RECORD_INDEX_LOCAL Locate one canonical tag within records.

            rec_idx = 0;
            if nargin < 1 || isempty(records) || ~isstruct(records)
                return;
            end
            for ii = 1:numel(records)
                if strcmp(run_warn_state_utils.state_value(records(ii), 'tag', '', 'text'), tag)
                    rec_idx = ii;
                    return;
                end
            end
        end

        function msg_txt = png_export_failure_warning_message_local(status_reason, output_path, export_err, print_err)
        % Build the canonical retained/emitted PNG export failure message text.

            output_path = char(string(output_path));
            export_err = char(string(export_err));
            print_err = char(string(print_err));
            if strcmp(status_reason, 'exportgraphics_failed')
                msg_txt = sprintf([ ...
                    'PNG export failed (subsequent failures are summarized in output I/O diagnostics). ', ...
                    'First file: %s (exportgraphics: %s; print fallback: %s)'], ...
                    output_path, export_err, print_err);
            elseif strcmp(status_reason, 'missing_exportgraphics')
                msg_txt = sprintf([ ...
                    'PNG export failed because exportgraphics is unavailable and print fallback also failed. ', ...
                    'First file: %s (print fallback: %s)'], ...
                    output_path, print_err);
            elseif strcmp(status_reason, 'invalid_status_payload')
                msg_txt = sprintf([ ...
                    'PNG export failure reporting received malformed status payload; treating export as failed. ', ...
                    'First file: %s. status detail: %s'], ...
                    output_path, print_err);
            else
                msg_txt = sprintf([ ...
                    'PNG export failed (subsequent failures are summarized in output I/O diagnostics). ', ...
                    'First file: %s via print fallback: %s'], ...
                    output_path, print_err);
            end
        end

        function phase_desc = phase_output_io_descriptor_local(phase_tag)
        % PHASE_OUTPUT_IO_DESCRIPTOR_LOCAL Human-readable category label for output-I/O summaries.

            phase_name = output_io_warn_utils.summary_output_io_phase_local(phase_tag);
            switch phase_name
                case 'setup'
                    phase_desc = 'setup output-io';
                case 'propagation'
                    phase_desc = 'propagation output-io';
                case 'end'
                    phase_desc = 'end-stage output-io';
            end
        end

        function [recent_phase_csv, recent_id_csv] = output_io_recent_summary_local(rec)
        % OUTPUT_IO_RECENT_SUMMARY_LOCAL Summarize bounded retained output-I/O history.

            recent_phase_csv = output_io_warn_utils.summary_output_io_phase_local(rec.last_phase);
            recent_id_csv = rec.last_error_id;
            if ~isstruct(rec) || ~isfield(rec, 'history') || ~isstruct(rec.history) || isempty(rec.history)
                return;
            end
            phase_tokens = {};
            id_tokens = {};
            for ii = 1:numel(rec.history)
                hist_event = rec.history(ii);
                phase_tokens{end+1} = output_io_warn_utils.summary_output_io_phase_local(hist_event.phase_tag); %#ok<AGROW>
                id_tokens{end+1} = hist_event.error_id; %#ok<AGROW>
            end
            recent_phase_csv = strjoin(output_io_warn_utils.unique_text_tokens_local(phase_tokens), ',');
            recent_id_csv = strjoin(output_io_warn_utils.unique_text_tokens_local(id_tokens), ',');
        end

        function [phase_name, invalid_phase_message] = normalize_output_io_phase_local(phase_raw, fallback_phase, field_name)
        % NORMALIZE_OUTPUT_IO_PHASE_LOCAL Map stored phase text onto setup/propagation/end summary buckets.

            if nargin < 2 || isempty(fallback_phase)
                fallback_phase = 'end';
            end
            if nargin < 3 || isempty(field_name)
                field_name = 'phase';
            end
            fallback_phase = output_io_warn_utils.canonical_output_io_phase_token_local( ...
                fallback_phase, 'end');
            invalid_phase_message = '';
            if nargin < 1 || isempty(phase_raw)
                phase_name = fallback_phase;
                invalid_phase_message = sprintf( ...
                    'Normalized output_io %s with missing/empty phase metadata to %s.', ...
                    field_name, phase_name);
                return;
            end
            if isstring(phase_raw) && isscalar(phase_raw)
                phase_raw = char(phase_raw);
            elseif ~ischar(phase_raw)
                phase_name = fallback_phase;
                invalid_phase_message = sprintf( ...
                    'Normalized output_io %s with non-text phase metadata to %s.', ...
                    field_name, phase_name);
                return;
            end
            raw = lower(strtrim(phase_raw));
            switch raw
                case {'setup', 'propagation', 'end'}
                    phase_name = raw;
                otherwise
                    phase_name = fallback_phase;
                    invalid_phase_message = sprintf( ...
                        'Normalized output_io %s with invalid phase metadata "%s" to %s.', ...
                        field_name, phase_raw, phase_name);
            end
        end

        function phase_name = summary_output_io_phase_local(phase_raw)
        % SUMMARY_OUTPUT_IO_PHASE_LOCAL Return the canonical live output-I/O phase name.

            phase_name = run_warn_state_utils.canonical_phase_name( ...
                phase_raw, 'CerUPP:InvalidOutputIOPhaseTag');
        end

        function phase_name = canonical_output_io_phase_token_local(phase_raw, default_phase)
        % CANONICAL_OUTPUT_IO_PHASE_TOKEN_LOCAL Return setup/propagation/end without recursive fallback normalization.

            if nargin < 2 || isempty(default_phase)
                default_phase = 'end';
            end
            phase_name = 'end';
            if isstring(default_phase) && isscalar(default_phase)
                default_phase = char(default_phase);
            end
            if ischar(default_phase)
                default_phase_raw = lower(strtrim(default_phase));
                switch default_phase_raw
                    case {'setup', 'propagation', 'end'}
                        phase_name = default_phase_raw;
                end
            end
            if nargin < 1 || isempty(phase_raw)
                return;
            end
            if isstring(phase_raw) && isscalar(phase_raw)
                phase_raw = char(phase_raw);
            end
            if ~ischar(phase_raw)
                return;
            end
            raw = lower(strtrim(phase_raw));
            switch raw
                case {'setup', 'propagation', 'end'}
                    phase_name = raw;
            end
        end

        function [count_value, invalid_count_message] = normalize_output_io_record_count_local(rec_in)
        % NORMALIZE_OUTPUT_IO_RECORD_COUNT_LOCAL Enforce integer event-counter semantics on stored counts.

            count_value = run_warn_state_utils.state_value(rec_in, 'count', 0, 'num');
            invalid_count_message = '';
            if (count_value >= 0) && (round(count_value) == count_value)
                count_value = double(count_value);
                return;
            end
            count_value_fixed = max(0, floor(double(count_value)));
            invalid_count_message = sprintf( ...
                'Normalized output_io record malformed count %g to nonnegative integer %d.', ...
                double(count_value), count_value_fixed);
            count_value = double(count_value_fixed);
        end

        function msg_out = append_output_io_normalization_note_local(msg_in, note_txt)
        % APPEND_OUTPUT_IO_NORMALIZATION_NOTE_LOCAL Preserve one normalization provenance note in last_message.

            if nargin < 1 || isempty(msg_in)
                msg_out = '';
            else
                msg_out = char(string(msg_in));
            end
            if nargin < 2 || isempty(note_txt)
                return;
            end
            note_txt = char(string(note_txt));
            if isempty(msg_out)
                msg_out = note_txt;
            else
                msg_out = sprintf('%s | %s', note_txt, msg_out);
            end
        end

        function tokens = unique_text_tokens_local(tokens_in)
        % UNIQUE_TEXT_TOKENS_LOCAL Stable unique token list for compact output-I/O summaries.

            tokens = {};
            if nargin < 1 || isempty(tokens_in)
                tokens = {'n/a'};
                return;
            end
            for ii = 1:numel(tokens_in)
                token = tokens_in{ii};
                if isempty(token)
                    token = 'n/a';
                end
                if ~any(strcmp(tokens, token))
                    tokens{end+1} = token; %#ok<AGROW>
                end
            end
            if isempty(tokens)
                tokens = {'n/a'};
            end
        end

    end
end
