classdef user_setup_guard
% Hard-fail if frozen setup compare baselines drift after CerUPP captures them.

    methods (Static)
        function guard = initialize(extension_surface_names)
        % Build one empty guard. extension_surface_names names the supported
        % custom post-freeze extension paths suggested for true extensions.
            if nargin < 1 || isempty(extension_surface_names)
                extension_surface_names = {'major_step_custom_args'};
            end
            extension_surface_names = ...
                user_setup_guard.normalize_extension_surface_names_local(extension_surface_names);
            guard = struct( ...
                'surfaces', struct(), ...
                'surface_labels', struct(), ...
                'enabled', true, ...
                'extension_surface_names', {extension_surface_names}, ...
                'extension_surface_name', extension_surface_names{1});
        end

        function guard = capture_surface(guard, surface_key, surface_label, surface_values, allow_overwrite)
        % Record one setup compare baseline (raw or built) once later edits
        % must no longer silently retarget the settled run state.
            guard = user_setup_guard.validate_guard_local(guard);
            surface_key = user_setup_guard.normalize_surface_key_local(surface_key);
            surface_label = user_setup_guard.normalize_text_local(surface_label, surface_key);
            user_setup_guard.validate_surface_values_local(surface_values, surface_key);
            if nargin < 5 || isempty(allow_overwrite)
                allow_overwrite = false;
            end
            allow_overwrite = logical(allow_overwrite);
            if isfield(guard.surfaces, surface_key) && ~allow_overwrite
                error('CerUPP:UserSetupGuardDuplicateSurfaceCapture', ...
                    ['user_setup_guard.capture_surface tried to recapture "%s". ', ...
                     'Freeze surfaces must be captured once unless an explicit ', ...
                     'allow_overwrite=true path is used.'], ...
                    surface_key);
            end
            guard.surfaces.(surface_key) = ...
                user_setup_guard.build_surface_compare_baseline_local( ...
                    surface_values, surface_key);
            guard.surface_labels.(surface_key) = surface_label;
        end

        function sealed_surfaces = build_sealed_surface_snapshot(guard)
        % Build one separate immutable-in-practice copy of the captured
        % compare baselines so later guard edits can be detected.

            guard = user_setup_guard.validate_guard_local(guard);
            sealed_surfaces = guard.surfaces;
        end

        function assert_guard_integrity(guard, sealed_surfaces)
        % Hard-fail if the captured compare baseline itself drifted after
        % Section 4 had already sealed the authoritative freeze record.

            guard = user_setup_guard.validate_guard_local(guard);
            if ~logical(guard.enabled)
                return;
            end
            if nargin < 2 || ~isstruct(sealed_surfaces) || ~isscalar(sealed_surfaces)
                error('CerUPP:UserSetupGuardInvalidSealedSurfaceBundle', ...
                    ['user_setup_guard.assert_guard_integrity requires one ', ...
                     'scalar struct of sealed freeze surfaces.']);
            end

            mismatch_list = {};
            sealed_surface_names = fieldnames(sealed_surfaces);
            for surface_idx = 1:numel(sealed_surface_names)
                surface_key = sealed_surface_names{surface_idx};
                if ~isfield(guard.surfaces, surface_key)
                    mismatch_list{end+1, 1} = sprintf( ... %#ok<AGROW>
                        '%s (captured guard lost this frozen surface)', ...
                        surface_key);
                    continue;
                end
                surface_label = surface_key;
                if isfield(guard.surface_labels, surface_key)
                    surface_label = guard.surface_labels.(surface_key);
                end
                mismatch_list = [mismatch_list; ... %#ok<AGROW>
                    user_setup_guard.collect_surface_mismatches_local( ...
                        surface_label, ...
                        sealed_surfaces.(surface_key), ...
                        user_setup_guard.build_surface_compare_baseline_local( ...
                            guard.surfaces.(surface_key), surface_key), ...
                        '')];
            end

            extra_surface_names = setdiff(fieldnames(guard.surfaces), ...
                sealed_surface_names, 'stable');
            for surface_idx = 1:numel(extra_surface_names)
                mismatch_list{end+1, 1} = sprintf( ... %#ok<AGROW>
                    '%s (captured guard gained an uncaptured surface)', ...
                    extra_surface_names{surface_idx});
            end

            if isempty(mismatch_list)
                return;
            end

            preview_count = min(numel(mismatch_list), 6);
            preview = strjoin(mismatch_list(1:preview_count), '; ');
            if numel(mismatch_list) > preview_count
                preview = sprintf( ...
                    '%s; ... (+%d more)', preview, numel(mismatch_list) - preview_count);
            end

            error('CerUPP:UserSetupGuardCapturedBaselineMutated', ...
                ['The captured freeze compare baseline was edited after ', ...
                 'Section 4 had already sealed it: %s. Section 5A refuses ', ...
                 'to trust a mutable freeze record as the authoritative ', ...
                 'reference. Edit the live input above the owning freeze ', ...
                 'block instead of rewriting setup_freeze_guard.surfaces or ', ...
                 'its sealed compare-baseline copy.'], ...
                preview);
        end

        function assert_clean(guard, current_surfaces)
        % Hard-fail when one captured setup surface (raw or built) was
        % edited later and would no longer change the settled run state.
            guard = user_setup_guard.validate_guard_local(guard);
            if ~logical(guard.enabled)
                return;
            end
            if nargin < 2 || ~isstruct(current_surfaces) || ~isscalar(current_surfaces)
                error('CerUPP:UserSetupGuardInvalidCurrentSurfaceBundle', ...
                    'user_setup_guard.assert_clean requires a scalar struct of current surfaces.');
            end

            mismatch_list = {};
            surface_names = fieldnames(guard.surfaces);
            for surface_idx = 1:numel(surface_names)
                surface_key = surface_names{surface_idx};
                if ~isfield(current_surfaces, surface_key)
                    error('CerUPP:UserSetupGuardMissingCurrentSurface', ...
                        'Current setup surface bundle is missing "%s".', surface_key);
                end
                current_surface_baseline = ...
                    user_setup_guard.build_surface_compare_baseline_local( ...
                        current_surfaces.(surface_key), surface_key);
                mismatch_list = [mismatch_list; ...
                    user_setup_guard.collect_surface_mismatches_local( ...
                        guard.surface_labels.(surface_key), ...
                        guard.surfaces.(surface_key), ...
                        current_surface_baseline, ...
                        '')]; %#ok<AGROW>
            end

            if isempty(mismatch_list)
                return;
            end

            preview_count = min(numel(mismatch_list), 6);
            preview = strjoin(mismatch_list(1:preview_count), '; ');
            if numel(mismatch_list) > preview_count
                preview = sprintf( ...
                    '%s; ... (+%d more)', preview, numel(mismatch_list) - preview_count);
            end

            extension_surface_guidance = ...
                user_setup_guard.describe_extension_surface_paths_local(guard.extension_surface_names);
            error('CerUPP:LateVisibleSetupEditAfterFreeze', ...
                ['A frozen setup surface changed after CerUPP had already captured it: %s. ', ...
                 'This is a hard error because that later edit did not change the built setup ', ...
                 'that propagation will use. Edit the live input above that freeze block in ', ...
                 'cerupp.m if you want the built setup to change. ', ...
                 'For medium changes, move the edit above the block that ', ...
                 'resolves medium_spec / propagation_medium_name / frozen_cfg_* or thread the ', ...
                 'late medium-builder input through medium_builder_custom_args, which the medium ', ...
                 'builder reads on the setup build and on later rebuilds only. The ', ...
                 'frozen_cfg_raw_* structs are guard snapshots and internal carry-forward ', ...
                 'references for some later settles, not a supported post-freeze override ', ...
                 'path. If you are adding a new per-step experimental input rather ', ...
                 'than changing an existing knob, thread that named input through %s into the ', ...
                 'helper that uses it.'], ...
                preview, extension_surface_guidance);
        end

        function assert_selected_clean(guard, current_surfaces)
        % Hard-fail when one selected captured setup surface was edited
        % later and would no longer change the settled run state.
            guard = user_setup_guard.validate_guard_local(guard);
            if ~logical(guard.enabled)
                return;
            end
            if nargin < 2 || ~isstruct(current_surfaces) || ~isscalar(current_surfaces)
                error('CerUPP:UserSetupGuardInvalidCurrentSurfaceBundle', ...
                    'user_setup_guard.assert_selected_clean requires a scalar struct of current surfaces.');
            end

            mismatch_list = {};
            surface_names = fieldnames(current_surfaces);
            for surface_idx = 1:numel(surface_names)
                surface_key = surface_names{surface_idx};
                if ~isfield(guard.surfaces, surface_key)
                    error('CerUPP:UserSetupGuardUnknownCurrentSurface', ...
                        'Current setup surface bundle included uncaptured surface "%s".', surface_key);
                end
                current_surface_baseline = ...
                    user_setup_guard.build_surface_compare_baseline_local( ...
                        current_surfaces.(surface_key), surface_key);
                mismatch_list = [mismatch_list; ...
                    user_setup_guard.collect_surface_mismatches_local( ...
                        guard.surface_labels.(surface_key), ...
                        guard.surfaces.(surface_key), ...
                        current_surface_baseline, ...
                        '')]; %#ok<AGROW>
            end

            if isempty(mismatch_list)
                return;
            end

            preview_count = min(numel(mismatch_list), 6);
            preview = strjoin(mismatch_list(1:preview_count), '; ');
            if numel(mismatch_list) > preview_count
                preview = sprintf( ...
                    '%s; ... (+%d more)', preview, numel(mismatch_list) - preview_count);
            end

            extension_surface_guidance = ...
                user_setup_guard.describe_extension_surface_paths_local(guard.extension_surface_names);
            error('CerUPP:LateVisibleSetupEditAfterFreeze', ...
                ['A frozen setup surface changed after CerUPP had already captured it: %s. ' ...
                 'This is a hard error because that later edit did not change the built setup ' ...
                 'that propagation will use. Edit the live input above that freeze block in ' ...
                 'cerupp.m if you want the built setup to change. ' ...
                 'For medium changes, move the edit above the block that ' ...
                 'resolves medium_spec / propagation_medium_name / frozen_cfg_* or thread the ' ...
                 'late medium-builder input through medium_builder_custom_args, which the medium ' ...
                 'builder reads on the setup build and on later rebuilds only. The ' ...
                 'frozen_cfg_raw_* structs are guard snapshots and internal carry-forward ' ...
                 'references for some later settles, not a supported post-freeze override ' ...
                 'path. If you are adding a new per-step experimental input rather ' ...
                 'than changing an existing knob, thread that named input through %s into the ' ...
                 'helper that uses it.'], ...
                preview, extension_surface_guidance);
        end
    end

    methods (Static, Hidden)
        function guard = validate_guard_local(guard)
            if nargin < 1 || isempty(guard) || ~isstruct(guard) || ~isscalar(guard)
                guard = struct();
            end
            if ~isfield(guard, 'surfaces') || ~isstruct(guard.surfaces) || ~isscalar(guard.surfaces)
                guard.surfaces = struct();
            end
            if ~isfield(guard, 'surface_labels') || ...
                    ~isstruct(guard.surface_labels) || ...
                    ~isscalar(guard.surface_labels)
                guard.surface_labels = struct();
            end
            if ~isfield(guard, 'enabled') || ~isscalar(guard.enabled)
                guard.enabled = true;
            end
            guard.enabled = logical(guard.enabled);
            legacy_extension_surface_name = '';
            if isfield(guard, 'extension_surface_name') && ~isempty(guard.extension_surface_name)
                legacy_extension_surface_name = char(string(guard.extension_surface_name));
            end
            if ~isfield(guard, 'extension_surface_names') || isempty(guard.extension_surface_names)
                if isempty(legacy_extension_surface_name)
                    guard.extension_surface_names = {'major_step_custom_args'};
                else
                    guard.extension_surface_names = ...
                        user_setup_guard.normalize_extension_surface_names_local( ...
                            legacy_extension_surface_name);
                end
            else
                guard.extension_surface_names = ...
                    user_setup_guard.normalize_extension_surface_names_local( ...
                        guard.extension_surface_names);
            end
            guard.extension_surface_name = guard.extension_surface_names{1};
        end

        function extension_surface_names = normalize_extension_surface_names_local( ...
                extension_surface_names)
            if ischar(extension_surface_names)
                extension_surface_names = {extension_surface_names};
            elseif isstring(extension_surface_names)
                extension_surface_names = cellstr(extension_surface_names(:).');
            elseif ~iscell(extension_surface_names)
                error('CerUPP:UserSetupGuardInvalidExtensionSurfaceNames', ...
                    ['extension_surface_names must be a char, scalar/string array, ', ...
                     'or cell array of char/string values.']);
            end

            normalized_names = cell(1, numel(extension_surface_names));
            for name_idx = 1:numel(extension_surface_names)
                name_value = extension_surface_names{name_idx};
                if isstring(name_value) && isscalar(name_value)
                    name_value = char(name_value);
                end
                if ~ischar(name_value) || isempty(strtrim(name_value))
                    error('CerUPP:UserSetupGuardInvalidExtensionSurfaceName', ...
                        'Each extension surface name must be a nonempty char or scalar string.');
                end
                normalized_names{name_idx} = strtrim(name_value);
            end
            extension_surface_names = unique(normalized_names, 'stable');
        end

        function surface_key = normalize_surface_key_local(surface_key)
            if isstring(surface_key) && isscalar(surface_key)
                surface_key = char(surface_key);
            end
            if ~ischar(surface_key) || isempty(strtrim(surface_key))
                error('CerUPP:UserSetupGuardInvalidSurfaceKey', ...
                    'Surface keys must be nonempty char or scalar string values.');
            end
            surface_key = matlab.lang.makeValidName(strtrim(surface_key));
        end

        function text_out = normalize_text_local(text_in, fallback_text)
            if nargin < 2 || isempty(fallback_text)
                fallback_text = '';
            end
            if isempty(text_in)
                text_out = char(string(fallback_text));
                return;
            end
            text_out = char(string(text_in));
        end

        function validate_surface_values_local(surface_values, surface_key)
            if nargin < 2 || isempty(surface_key)
                surface_key = 'user_setup_surface';
            end
            if ~(isstruct(surface_values) && isscalar(surface_values))
                error('CerUPP:UserSetupGuardInvalidSurfaceValue', ...
                    'Surface "%s" must be captured as a scalar struct.', surface_key);
            end
        end

        function surface_compare_baseline = build_surface_compare_baseline_local( ...
                surface_values, surface_key)
            if nargin < 2 || isempty(surface_key)
                surface_key = 'user_setup_surface';
            end
            user_setup_guard.validate_surface_values_local(surface_values, surface_key);
            surface_compare_baseline = ...
                driver_setup_support.build_value_freeze_signature_local( ...
                    surface_values);
            if ~(isstruct(surface_compare_baseline) && isscalar(surface_compare_baseline))
                error('CerUPP:UserSetupGuardInvalidCompareBaseline', ...
                    ['Surface "%s" did not normalize into one scalar compare ', ...
                     'baseline struct.'], ...
                    surface_key);
            end
        end

        function mismatch_list = collect_surface_mismatches_local( ...
                surface_label, expected_value, actual_value, path_prefix)
            mismatch_list = {};
            if isstruct(expected_value) && isscalar(expected_value)
                if ~(isstruct(actual_value) && isscalar(actual_value))
                    mismatch_list = {sprintf('%s -> %s (expected struct, saw %s)', ...
                        surface_label, ...
                        user_setup_guard.path_or_surface_local(path_prefix), ...
                        user_setup_guard.summarize_value_local(actual_value))};
                    return;
                end
                expected_fields = fieldnames(expected_value);
                for field_idx = 1:numel(expected_fields)
                    field_name = expected_fields{field_idx};
                    next_path = user_setup_guard.extend_path_local(path_prefix, field_name);
                    if ~isfield(actual_value, field_name)
                        mismatch_list{end+1, 1} = sprintf( ...
                            '%s -> %s (current surface missing field)', ...
                            surface_label, next_path); %#ok<AGROW>
                        continue;
                    end
                    mismatch_list = [mismatch_list; ...
                        user_setup_guard.collect_surface_mismatches_local( ...
                            surface_label, expected_value.(field_name), ...
                            actual_value.(field_name), next_path)]; %#ok<AGROW>
                end
                extra_fields = setdiff(fieldnames(actual_value), expected_fields, 'stable');
                for field_idx = 1:numel(extra_fields)
                    field_name = extra_fields{field_idx};
                    next_path = user_setup_guard.extend_path_local(path_prefix, field_name);
                    mismatch_list{end+1, 1} = sprintf( ...
                        '%s -> %s (current surface has unexpected extra field)', ...
                        surface_label, next_path); %#ok<AGROW>
                end
                return;
            end

            if user_setup_guard.values_equal_local(expected_value, actual_value)
                return;
            end

            mismatch_list = {sprintf('%s -> %s (expected %s, saw %s)', ...
                surface_label, ...
                user_setup_guard.path_or_surface_local(path_prefix), ...
                user_setup_guard.summarize_value_local(expected_value), ...
                user_setup_guard.summarize_value_local(actual_value))};
        end

        function next_path = extend_path_local(path_prefix, field_name)
            if nargin < 1 || isempty(path_prefix)
                next_path = char(string(field_name));
            else
                next_path = sprintf('%s.%s', path_prefix, char(string(field_name)));
            end
        end

        function path_text = path_or_surface_local(path_prefix)
            if nargin < 1 || isempty(path_prefix)
                path_text = '(surface root)';
            else
                path_text = path_prefix;
            end
        end

        function tf = values_equal_local(expected_value, actual_value)
            if (isnumeric(expected_value) || islogical(expected_value)) && ...
                    (isnumeric(actual_value) || islogical(actual_value))
                if isscalar(expected_value) && isscalar(actual_value)
                    tf = isequaln(double(expected_value), double(actual_value));
                    return;
                end
                tf = isequaln(expected_value, actual_value);
                return;
            end

            expected_is_text = ischar(expected_value) || ...
                (isstring(expected_value) && isscalar(expected_value));
            actual_is_text = ischar(actual_value) || ...
                (isstring(actual_value) && isscalar(actual_value));
            if expected_is_text && actual_is_text
                tf = strcmp(char(string(expected_value)), char(string(actual_value)));
                return;
            end

            tf = isequaln(expected_value, actual_value);
        end

        function value_text = summarize_value_local(value_in)
            if isempty(value_in)
                value_text = '[]';
                return;
            end

            if islogical(value_in) && isscalar(value_in)
                value_text = char(string(value_in));
                return;
            end

            if isnumeric(value_in) && isscalar(value_in)
                if isreal(value_in)
                    value_text = sprintf('%.12g', double(value_in));
                else
                    value_text = sprintf('%.12g%+.12gi', real(double(value_in)), imag(double(value_in)));
                end
                return;
            end

            if ischar(value_in) || (isstring(value_in) && isscalar(value_in))
                text_value = char(string(value_in));
                if numel(text_value) > 48
                    text_value = [text_value(1:45) '...'];
                end
                value_text = ['''' text_value ''''];
                return;
            end

            if isnumeric(value_in) || islogical(value_in)
                size_text = sprintf('%dx', size(value_in));
                size_text = size_text(1:end-1);
                value_text = sprintf('%s [%s]', class(value_in), size_text);
                return;
            end

            if isstruct(value_in)
                value_text = 'struct';
                return;
            end

            if iscell(value_in)
                size_text = sprintf('%dx', size(value_in));
                size_text = size_text(1:end-1);
                value_text = sprintf('cell [%s]', size_text);
                return;
            end

            value_text = class(value_in);
        end

        function guidance_text = describe_extension_surface_paths_local(extension_surface_names)
            extension_surface_names = ...
                user_setup_guard.normalize_extension_surface_names_local(extension_surface_names);
            guidance_parts = cell(1, numel(extension_surface_names));
            for name_idx = 1:numel(extension_surface_names)
                surface_name = extension_surface_names{name_idx};
                switch surface_name
                    case 'major_step_custom_args'
                        guidance_parts{name_idx} = ...
                            'major_step_custom_args.<stage>.<name> for per-step hooks';
                    case 'medium_builder_custom_args'
                        guidance_parts{name_idx} = ...
                            ['medium_builder_custom_args.<name> for calculate_medium_properties_z(...) ', ...
                             'inputs read on setup and on later rebuilds'];
                    otherwise
                        guidance_parts{name_idx} = sprintf('%s.<name>', surface_name);
                end
            end

            if numel(guidance_parts) == 1
                guidance_text = guidance_parts{1};
                return;
            end

            guidance_text = [strjoin(guidance_parts(1:end-1), ', ') ', or ' guidance_parts{end}];
        end
    end
end
