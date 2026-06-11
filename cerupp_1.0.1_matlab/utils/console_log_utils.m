classdef console_log_utils
%CONSOLE_LOG_UTILS Mirror CerUPP command-window output into one run-folder text log.
% cerupp.m can bootstrap a temporary diary at file entry, then this helper
% promotes that early log into the resolved run folder once startup creates it.

    methods (Static)
        function [console_log_ctx, run_warn_state] = start_console_output_log(cfg, run_warn_state)
        % Start one command-window mirror log in the current run output root.

            if nargin < 1 || ~isstruct(cfg)
                error('CerUPP:ConsoleLog:InvalidCfg', ...
                    'start_console_output_log requires a scalar cfg struct.');
            end
            if nargin < 2 || ~(isstruct(run_warn_state) && isscalar(run_warn_state))
                run_warn_state = struct_utils.ensure_warned_keys_map(struct());
            end

            run_output_root = char(string(struct_utils.req_struct_field( ...
                cfg, 'run_output_root', 'console_log_cfg')));
            enable_console_output_log_flag = logical(struct_utils.opt_struct_field( ...
                cfg, 'enable_console_output_log_flag', true));
            log_name = char(string(struct_utils.opt_struct_field( ...
                cfg, 'log_name', 'cerupp_console_output_log.txt')));
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                struct_utils.opt_struct_field(cfg, 'phase_tag', 'setup'));

            console_log_ctx = struct( ...
                'enabled', false, ...
                'started_here', false, ...
                'log_path', '', ...
                'phase_tag', phase_tag);

            if ~enable_console_output_log_flag
                return;
            end

            if isempty(run_output_root)
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, phase_tag, 'console_output_log_missing_root', ...
                    'CerUPP:Output:ConsoleOutputLogMissingRoot', ...
                    ['Could not start the command-window mirror log because run_output_root is empty. ', ...
                     'cerupp.m console output will not be copied into a run-folder text log for this run.']);
                return;
            end

            if ~isfolder(run_output_root)
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, phase_tag, 'console_output_log_missing_root_dir', ...
                    'CerUPP:Output:ConsoleOutputLogMissingRootDir', ...
                    ['Could not start the command-window mirror log because run_output_root "%s" ', ...
                     'does not exist. Startup artifact setup owns that directory creation, so ', ...
                     'cerupp.m console output will not be copied into a run-folder text log.'], ...
                    run_output_root);
                return;
            end

            diary_active_before = false;
            try
                diary_active_before = strcmpi(string(get(0, 'Diary')), "on");
            catch
            end
            if diary_active_before
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, phase_tag, 'console_output_log_existing_diary_active', ...
                    'CerUPP:Output:ConsoleOutputLogExistingDiaryActive', ...
                    ['Could not start the command-window mirror log because MATLAB diary is already active. ', ...
                     'cerupp.m leaves that session-global diary owner unchanged, so this run will not ', ...
                     'start an additional run-folder console log.']);
                return;
            end

            log_path = fullfile(run_output_root, log_name);
            try
                diary(log_path);
                console_log_ctx.enabled = true;
                console_log_ctx.started_here = true;
                console_log_ctx.log_path = log_path;
            catch me_diary
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, phase_tag, 'console_output_log_start_failed', ...
                    'CerUPP:Output:ConsoleOutputLogStartFailed', ...
                    ['Could not start the command-window mirror log "%s". ', ...
                     'cerupp.m console output will not be copied into a run-folder text log. ', ...
                     'diary error: %s'], ...
                    log_path, me_diary.message);
            end
        end

        function [console_log_ctx, run_warn_state] = promote_or_start_console_output_log(cfg, run_warn_state)
        % Promote an early bootstrap diary into the run folder, or start
        % the run-folder diary directly when no bootstrap diary exists.

            if nargin < 1 || ~isstruct(cfg) || ~isscalar(cfg)
                error('CerUPP:ConsoleLog:InvalidPromotionCfg', ...
                    'promote_or_start_console_output_log requires a scalar cfg struct.');
            end
            if nargin < 2 || ~(isstruct(run_warn_state) && isscalar(run_warn_state))
                run_warn_state = struct_utils.ensure_warned_keys_map(struct());
            end

            console_log_ctx = struct_utils.opt_struct_field(cfg, 'console_log_ctx', struct());
            if ~(isstruct(console_log_ctx) && isscalar(console_log_ctx))
                console_log_ctx = struct();
            end
            if ~isfield(console_log_ctx, 'enabled'), console_log_ctx.enabled = false; end
            if ~isfield(console_log_ctx, 'started_here'), console_log_ctx.started_here = false; end
            if ~isfield(console_log_ctx, 'log_path'), console_log_ctx.log_path = ''; end
            if ~isfield(console_log_ctx, 'phase_tag'), console_log_ctx.phase_tag = 'setup'; end
            if ~isfield(console_log_ctx, 'bootstrap_enabled'), console_log_ctx.bootstrap_enabled = false; end
            if ~isfield(console_log_ctx, 'bootstrap_log_path'), console_log_ctx.bootstrap_log_path = ''; end
            if ~isfield(console_log_ctx, 'final_log_path'), console_log_ctx.final_log_path = ''; end
            if ~isfield(console_log_ctx, 'bootstrap_promoted'), console_log_ctx.bootstrap_promoted = false; end
            if ~isfield(console_log_ctx, 'pending_issue_code'), console_log_ctx.pending_issue_code = ''; end
            if ~isfield(console_log_ctx, 'pending_issue_message'), console_log_ctx.pending_issue_message = ''; end

            run_output_root = char(string(struct_utils.req_struct_field( ...
                cfg, 'run_output_root', 'console_log_cfg')));
            log_name = char(string(struct_utils.opt_struct_field( ...
                cfg, 'log_name', 'cerupp_console_output_log.txt')));
            phase_tag = run_warn_state_utils.canonical_phase_name( ...
                struct_utils.opt_struct_field(cfg, 'phase_tag', console_log_ctx.phase_tag));
            console_log_ctx.phase_tag = phase_tag;

            bootstrap_active = console_log_ctx.bootstrap_enabled && ...
                console_log_ctx.enabled && console_log_ctx.started_here && ...
                ~isempty(console_log_ctx.bootstrap_log_path);
            if ~bootstrap_active
                if strcmp(console_log_ctx.pending_issue_code, 'bootstrap_start_failed')
                    run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                        run_warn_state, phase_tag, ...
                        'console_output_log_bootstrap_start_failed', ...
                        'CerUPP:Output:ConsoleOutputLogBootstrapStartFailed', ...
                        ['Could not start the early bootstrap console log before startup. ', ...
                         'CerUPP will still try to start the run-folder console log here. ', ...
                         'diary error: %s'], ...
                        console_log_ctx.pending_issue_message);
                end
                [console_log_ctx, run_warn_state] = ...
                    console_log_utils.start_console_output_log( ...
                        struct( ...
                            'run_output_root', run_output_root, ...
                            'enable_console_output_log_flag', true, ...
                            'log_name', log_name, ...
                            'phase_tag', phase_tag), ...
                        run_warn_state);
                if console_log_ctx.enabled
                    console_log_ctx.final_log_path = console_log_ctx.log_path;
                end
                return;
            end

            if isempty(run_output_root) || ~isfolder(run_output_root)
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, phase_tag, ...
                    'console_output_log_bootstrap_promotion_skipped', ...
                    'CerUPP:Output:ConsoleOutputLogBootstrapPromotionSkipped', ...
                    ['Could not promote the bootstrap console log because run_output_root "%s" ', ...
                     'is unavailable. CerUPP will keep logging into "%s" instead.'], ...
                    run_output_root, console_log_ctx.bootstrap_log_path);
                return;
            end

            final_log_path = fullfile(run_output_root, log_name);
            try
                diary off;
                console_log_utils.append_text_file_local( ...
                    console_log_ctx.bootstrap_log_path, final_log_path);
                diary(final_log_path);
                console_log_ctx.enabled = true;
                console_log_ctx.started_here = true;
                console_log_ctx.log_path = final_log_path;
                console_log_ctx.final_log_path = final_log_path;
                console_log_ctx.bootstrap_promoted = true;
            catch me_promote
                restore_ok = false;
                try
                    diary(console_log_ctx.bootstrap_log_path);
                    restore_ok = true;
                catch
                end
                console_log_ctx.enabled = restore_ok;
                console_log_ctx.started_here = restore_ok;
                if restore_ok
                    console_log_ctx.log_path = console_log_ctx.bootstrap_log_path;
                end
                run_warn_state = run_warn_state_utils.emit_warn_once_with_phase( ...
                    run_warn_state, phase_tag, ...
                    'console_output_log_bootstrap_promotion_failed', ...
                    'CerUPP:Output:ConsoleOutputLogBootstrapPromotionFailed', ...
                    ['Could not promote the bootstrap console log into "%s". ', ...
                     'CerUPP kept or attempted to restore logging in "%s". ', ...
                     'Error: %s'], ...
                    final_log_path, console_log_ctx.bootstrap_log_path, me_promote.message);
            end
        end

        function stop_console_output_log(console_log_ctx)
        % Stop the command-window mirror log for this run.

            if nargin < 1 || ~isstruct(console_log_ctx)
                return;
            end
            if ~(isfield(console_log_ctx, 'enabled') && console_log_ctx.enabled)
                return;
            end
            if isfield(console_log_ctx, 'started_here') && ~console_log_ctx.started_here
                return;
            end
            try
                diary off;
            catch
            end
            if isfield(console_log_ctx, 'bootstrap_promoted') && ...
                    console_log_ctx.bootstrap_promoted && ...
                    isfield(console_log_ctx, 'bootstrap_log_path') && ...
                    ~isempty(console_log_ctx.bootstrap_log_path) && ...
                    (exist(console_log_ctx.bootstrap_log_path, 'file') == 2)
                try
                    delete(console_log_ctx.bootstrap_log_path);
                catch
                end
            end
        end
    end

    methods (Static, Access = private)
        function append_text_file_local(src_path, dst_path)
            if isempty(src_path) || (exist(src_path, 'file') ~= 2)
                return;
            end

            dst_dir = fileparts(dst_path);
            if ~isempty(dst_dir) && ~isfolder(dst_dir)
                mkdir(dst_dir);
            end

            fid_src = fopen(src_path, 'r');
            if fid_src < 0
                error('CerUPP:ConsoleLog:OpenBootstrapFailed', ...
                    'Could not open bootstrap console log "%s" for reading.', src_path);
            end
            src_cleanup = onCleanup(@() fclose(fid_src)); %#ok<NASGU>

            fid_dst = fopen(dst_path, 'a');
            if fid_dst < 0
                error('CerUPP:ConsoleLog:OpenFinalFailed', ...
                    'Could not open final console log "%s" for appending.', dst_path);
            end
            dst_cleanup = onCleanup(@() fclose(fid_dst)); %#ok<NASGU>

            data = fread(fid_src, Inf, '*uint8');
            if ~isempty(data)
                fwrite(fid_dst, data, 'uint8');
            end
        end
    end
end
