classdef struct_utils
%STRUCT_UTILS Shared struct-field helpers plus narrow restart schema constants.
% Purpose:
% - Provide the small helper surface for struct-field access, unpacking,
%   and narrow restart-schema constants.
% Called across setup, propagation, restart, and plotting helpers.

    methods (Static)
        function v = req_struct_field(s, field_name, ctx_name, varargin)
        %REQ_STRUCT_FIELD Required-field accessor with configurable error IDs/messages.

            defaults = struct( ...
                'err_id_notstruct', 'struct_utils:SourceNotStruct', ...
                'err_msg_notstruct', '%s must be a struct.', ...
                'err_id_missing', 'struct_utils:MissingStructField', ...
                'err_msg_missing', 'Missing required field %s.%s.');
            opts = struct_utils.merge_opts_local(defaults, varargin{:});

            if (nargin < 3) || isempty(ctx_name)
                ctx_name = 'args';
            end
            if isstring(field_name) && isscalar(field_name)
                field_name = char(field_name);
            end
            if ~ischar(field_name)
                error('struct_utils:InvalidFieldName', ...
                    'field_name must be char or scalar string.');
            end
            if ~isstruct(s)
                error(opts.err_id_notstruct, opts.err_msg_notstruct, ctx_name);
            end
            if ~isfield(s, field_name)
                error(opts.err_id_missing, opts.err_msg_missing, ctx_name, field_name);
            end
            v = s.(field_name);
        end

        function v = opt_struct_field(s, field_name, default_value, varargin)
        %OPT_STRUCT_FIELD Optional-field accessor with configurable behavior.

            defaults = struct( ...
                'treat_empty_as_missing', false, ...
                'require_struct', false, ...
                'err_id_notstruct', 'struct_utils:SourceNotStruct', ...
                'err_msg_notstruct', '%s must be a struct.', ...
                'context_name', 'args');
            opts = struct_utils.merge_opts_local(defaults, varargin{:});

            if isstring(field_name) && isscalar(field_name)
                field_name = char(field_name);
            end
            if ~ischar(field_name)
                error('struct_utils:InvalidFieldName', ...
                    'field_name must be char or scalar string.');
            end

            if ~isstruct(s)
                if logical(opts.require_struct)
                    error(opts.err_id_notstruct, opts.err_msg_notstruct, opts.context_name);
                end
                v = default_value;
                return;
            end

            if ~isfield(s, field_name)
                v = default_value;
                return;
            end

            v = s.(field_name);
            if logical(opts.treat_empty_as_missing) && isempty(v)
                v = default_value;
            end
        end

        function s = ensure_warned_keys_map(s, reset_map)
        %ENSURE_WARNED_KEYS_MAP Normalize run-local warn-once state shape.
        % Contract:
        % - Ensure s.warned_keys exists as a value-semantic per-run set of
        %   emitted warning keys.
        % - Optional reset_map=true recreates the set to clear prior keys.
        % - Live canonical storage is a column cell array of nonempty char
        %   keys.
        % - A present warned_keys field with the wrong type is treated as
        %   malformed caller state rather than silently reset.
        % - Caller-owned state avoids persistent/global warn-once behavior.

            if (nargin < 2) || isempty(reset_map)
                reset_map = false;
            else
                reset_map = logical(reset_map);
            end
            if (nargin < 1) || isempty(s) || ~isstruct(s)
                s = struct();
            end
            if reset_map || ~isfield(s, 'warned_keys')
                s.warned_keys = cell(0, 1);
            else
                s.warned_keys = struct_utils.normalize_warned_keys_set_local(s.warned_keys);
            end
        end

        function s = clone_warned_keys_map(s)
        %CLONE_WARNED_KEYS_MAP Deep-copy warned_keys so warning ledgers stay value-semantic.

            if (nargin < 1) || isempty(s) || ~isstruct(s)
                s = struct();
            end
            s = struct_utils.ensure_warned_keys_map(s);
            s.warned_keys = reshape(s.warned_keys, [], 1);
        end

        function merged_state = merge_warned_keys_maps(base_state, update_state)
        %MERGE_WARNED_KEYS_MAPS Union two caller-owned warn-once ledgers.

            merged_state = struct_utils.clone_warned_keys_map( ...
                struct_utils.ensure_warned_keys_map(base_state));
            update_state = struct_utils.ensure_warned_keys_map(update_state);
            for key_idx = 1:numel(update_state.warned_keys)
                merged_state = struct_utils.add_warned_key( ...
                    merged_state, update_state.warned_keys{key_idx});
            end
        end

        function tf = warned_key_seen(s, warn_key)
        %WARNED_KEY_SEEN True when warn_key is already latched in s.warned_keys.

            s = struct_utils.ensure_warned_keys_map(s);
            warn_key = struct_utils.normalize_warned_key_local(warn_key);
            tf = any(strcmp(s.warned_keys, warn_key));
        end

        function s = add_warned_key(s, warn_key)
        %ADD_WARNED_KEY Latch warn_key once in the caller-owned warned_keys set.

            s = struct_utils.ensure_warned_keys_map(s);
            warn_key = struct_utils.normalize_warned_key_local(warn_key);
            if ~any(strcmp(s.warned_keys, warn_key))
                s.warned_keys{end+1, 1} = warn_key;
            end
        end

        function v = normalize_bool_scalar(v_in, name, err_id)
        %NORMALIZE_BOOL_SCALAR Normalize scalar bool-like controls: logical, or numeric 0/1.

            if nargin < 3 || isempty(err_id)
                err_id = 'struct_utils:InvalidBoolScalar';
            end
            ok = isscalar(v_in) && ( ...
                islogical(v_in) || ...
                (isnumeric(v_in) && isreal(v_in) && isfinite(v_in) && (v_in == 0 || v_in == 1)) );
            if ~ok
                error(err_id, '%s must be scalar logical or numeric in {0,1}.', name);
            end
            v = logical(v_in);
        end

        function [requested_order, effective_order] = normalize_nonparaxial_order(order_in, min_even_order, max_even_order)
        %NORMALIZE_NONPARAXIAL_ORDER Canonical coercion to supported even nonparaxial order.
        % Contract:
        % - requested_order = real scalar value provided by caller.
        % - effective_order is coerced to even order within [min_even_order, max_even_order].
        % - Behavior matches CerUPP normalization used by medium/operator builders.

            if nargin < 2 || isempty(min_even_order)
                min_even_order = 2;
            end
            if nargin < 3 || isempty(max_even_order)
                max_even_order = 8;
            end
            validateattributes(order_in, {'numeric'}, {'real','scalar','finite'}, ...
                mfilename, 'order_in');
            validateattributes(min_even_order, {'numeric'}, {'real','scalar','finite'}, ...
                mfilename, 'min_even_order');
            validateattributes(max_even_order, {'numeric'}, {'real','scalar','finite'}, ...
                mfilename, 'max_even_order');

            min_even_order = double(min_even_order);
            max_even_order = double(max_even_order);
            if (min_even_order <= 0) || (mod(min_even_order, 2) ~= 0)
                error('struct_utils:InvalidMinEvenOrder', ...
                    'min_even_order must be a positive even scalar; got %g.', min_even_order);
            end
            if (max_even_order < min_even_order) || (mod(max_even_order, 2) ~= 0)
                error('struct_utils:InvalidMaxEvenOrder', ...
                    'max_even_order must be an even scalar >= min_even_order; got %g.', max_even_order);
            end

            requested_order = double(real(order_in));
            if requested_order <= min_even_order
                effective_order = min_even_order;
                return;
            end
            effective_order = 2 * floor(requested_order / 2);
            effective_order = min(max(effective_order, min_even_order), max_even_order);
        end

        function required_groups = restart_required_groups()
        %RESTART_REQUIRED_GROUPS Canonical required top-level restart payload groups.

            required_groups = {'progress', 'state', 'grid', 'medium', 'ops'};
        end

        function varargout = unpack_struct_fields(s, names, context_name, varargin)
        %UNPACK_STRUCT_FIELDS Unpack required fields from a struct in one call.
        % If outputs are requested, nargout must exactly match the number
        % of field names supplied in NAMES.

            defaults = struct( ...
                'err_id_notstruct', 'struct_utils:UnpackSourceNotStruct', ...
                'err_msg_notstruct', '%s must be a struct.', ...
                'err_id_namesnotcell', 'struct_utils:UnpackNamesNotCell', ...
                'err_msg_namesnotcell', 'names must be a cell array of field names.', ...
                'err_id_missing', 'struct_utils:MissingUnpackFields', ...
                'err_msg_missing', '%s missing required fields: %s', ...
                'err_id_arity', 'struct_utils:UnpackArityMismatch', ...
                'err_msg_arity', 'Unpack arity mismatch in %s: requested %d outputs for %d fields.');
            opts = struct_utils.merge_opts_local(defaults, varargin{:});

            if (nargin < 3) || isempty(context_name)
                context_name = 'args';
            end
            if ~isstruct(s)
                error(opts.err_id_notstruct, opts.err_msg_notstruct, context_name);
            end
            if ~iscell(names)
                error(opts.err_id_namesnotcell, opts.err_msg_namesnotcell);
            end

            name_list = cell(1, numel(names));
            for ii = 1:numel(names)
                nm = names{ii};
                if isstring(nm) && isscalar(nm)
                    nm = char(nm);
                end
                if ~ischar(nm)
                    error('struct_utils:InvalidFieldNameList', ...
                        'Field names must be char or scalar string entries.');
                end
                name_list{ii} = nm;
            end

            missing = name_list(~isfield(s, name_list));
            if ~isempty(missing)
                error(opts.err_id_missing, opts.err_msg_missing, context_name, strjoin(missing, ', '));
            end

            vals = cell(1, numel(name_list));
            for ii = 1:numel(name_list)
                vals{ii} = s.(name_list{ii});
            end
            if (nargout > 0) && (nargout ~= numel(vals))
                error(opts.err_id_arity, opts.err_msg_arity, ...
                    context_name, nargout, numel(vals));
            end
            varargout = vals;
        end

        function s = allocate_diag_store_fields(enable_flag, field_specs, like_value)
        %ALLOCATE_DIAG_STORE_FIELDS Allocate or clear diagnostic-store fields from a {field,fill,size} spec.

            if nargin < 3
                like_value = [];
            end
            if ~iscell(field_specs) || (size(field_specs, 2) ~= 3)
                error('CerUPP:AllocateDiagStoreBadSpec', ...
                    'field_specs must be an N-by-3 cell array.');
            end
            enable_flag = struct_utils.normalize_bool_scalar( ...
                enable_flag, 'enable_flag', 'CerUPP:AllocateDiagStoreBadEnableFlag');
            s = struct();
            for ii = 1:size(field_specs, 1)
                field_name = field_specs{ii, 1};
                fill_kind = field_specs{ii, 2};
                size_spec = field_specs{ii, 3};
                if ~enable_flag
                    s.(field_name) = [];
                    continue;
                end
                switch fill_kind
                    case 'zeros'
                        if isempty(like_value)
                            s.(field_name) = zeros(size_spec);
                        else
                            s.(field_name) = zeros(size_spec, 'like', like_value);
                        end
                    case 'nan'
                        if isempty(like_value)
                            s.(field_name) = nan(size_spec);
                        else
                            s.(field_name) = nan(size_spec, 'like', like_value);
                        end
                    otherwise
                        error('CerUPP:AllocateDiagStoreBadFillKind', ...
                            'Unknown diagnostic storage fill kind "%s" for field "%s".', ...
                            fill_kind, field_name);
                end
            end
        end

        function x_out = trim_storage_axis(x_in, n_keep, axis_dim)
        %TRIM_STORAGE_AXIS Trim storage arrays to the first n_keep entries along axis_dim.
        % Empty inputs are returned unchanged.

            x_out = x_in;
            if isempty(x_out)
                return;
            end
            if ~isscalar(n_keep) || ~isfinite(n_keep) || (n_keep < 0) || (round(n_keep) ~= n_keep)
                error('CerUPP:TrimStorageBadCount', ...
                    'n_keep must be a finite nonnegative integer, got %s.', mat2str(n_keep));
            end
            if ~isscalar(axis_dim) || ~isfinite(axis_dim) || (axis_dim < 0) || (round(axis_dim) ~= axis_dim)
                error('CerUPP:TrimStorageBadDim', ...
                    'axis_dim must be a finite nonnegative integer, got %s.', mat2str(axis_dim));
            end
            n_keep = double(n_keep);
            axis_dim = double(axis_dim);
            if axis_dim == 0
                return;
            end
            nd = max(ndims(x_out), axis_dim);
            sz = size(x_out);
            sz_full = ones(1, nd);
            sz_full(1:numel(sz)) = sz;
            if sz_full(axis_dim) < n_keep
                error('CerUPP:TrimStorageOutOfBounds', ...
                    'Cannot trim dim %d of size %d to n_keep=%d.', ...
                    axis_dim, sz_full(axis_dim), n_keep);
            end
            if sz_full(axis_dim) == n_keep
                return;
            end
            idx = repmat({':'}, 1, nd);
            idx{axis_dim} = 1:n_keep;
            x_out = x_out(idx{:});
        end

        function x_out = slice_storage_axis(x_in, idx_first, idx_last, axis_dim)
        %SLICE_STORAGE_AXIS Slice storage arrays on axis_dim using inclusive bounds.
        % Empty inputs are returned unchanged.

            x_out = x_in;
            if isempty(x_out)
                return;
            end
            if ~isscalar(idx_first) || ~isfinite(idx_first) || (idx_first < 1) || ...
                    (round(idx_first) ~= idx_first)
                error('CerUPP:SliceStorageBadFirstIndex', ...
                    'idx_first must be a finite positive integer, got %s.', mat2str(idx_first));
            end
            if ~isscalar(idx_last) || ~isfinite(idx_last) || (idx_last < idx_first) || ...
                    (round(idx_last) ~= idx_last)
                error('CerUPP:SliceStorageBadLastIndex', ...
                    'idx_last must be a finite integer >= idx_first, got %s.', mat2str(idx_last));
            end
            if ~isscalar(axis_dim) || ~isfinite(axis_dim) || (axis_dim < 0) || ...
                    (round(axis_dim) ~= axis_dim)
                error('CerUPP:SliceStorageBadDim', ...
                    'axis_dim must be a finite nonnegative integer, got %s.', mat2str(axis_dim));
            end
            idx_first = double(idx_first);
            idx_last = double(idx_last);
            axis_dim = double(axis_dim);
            if axis_dim == 0
                return;
            end
            nd = max(ndims(x_out), axis_dim);
            sz = size(x_out);
            sz_full = ones(1, nd);
            sz_full(1:numel(sz)) = sz;
            if sz_full(axis_dim) < idx_last
                error('CerUPP:SliceStorageOutOfBounds', ...
                    'Cannot slice dim %d of size %d with idx_last=%d.', ...
                    axis_dim, sz_full(axis_dim), idx_last);
            end
            idx = repmat({':'}, 1, nd);
            idx{axis_dim} = idx_first:idx_last;
            x_out = x_out(idx{:});
        end

    end

    methods (Static, Access = private)
        function warned_keys = normalize_warned_keys_set_local(warned_keys_in)
            if ischar(warned_keys_in)
                warned_keys = {warned_keys_in};
            elseif isstring(warned_keys_in)
                warned_keys = cellstr(warned_keys_in(:));
            elseif iscell(warned_keys_in)
                warned_keys = warned_keys_in(:);
            else
                error('CerUPP:InvalidWarnedKeysMap', ...
                    ['warned_keys must be a cellstr/string set when present; got %s. ' ...
                     'Pass struct() for fresh state or reset_map=true to clear it intentionally.'], ...
                    class(warned_keys_in));
            end

            if isempty(warned_keys)
                warned_keys = cell(0, 1);
                return;
            end

            for kk = 1:numel(warned_keys)
                warned_keys{kk} = struct_utils.normalize_warned_key_local(warned_keys{kk});
            end
            warned_keys = unique(reshape(warned_keys, [], 1), 'stable');
        end

        function warn_key = normalize_warned_key_local(warn_key_in)
            if isstring(warn_key_in) && isscalar(warn_key_in)
                warn_key_in = char(warn_key_in);
            end
            if ~ischar(warn_key_in)
                error('CerUPP:InvalidWarnedKey', ...
                    'warned_keys entries must be char or scalar string; got %s.', class(warn_key_in));
            end
            warn_key = strtrim(warn_key_in);
            if isempty(warn_key)
                error('CerUPP:InvalidWarnedKey', ...
                    'warned_keys entries must be nonempty after trimming.');
            end
        end

        function opts = merge_opts_local(defaults, varargin)
        %MERGE_OPTS_LOCAL Merge defaults with struct or name/value options.
        % Explicit empty override values are honored unless allow_empty_values=false is provided.

            opts = defaults;
            allow_empty_values = true;
            if isempty(varargin)
                return;
            end
            unknown = {};

            if (numel(varargin) == 1) && isstruct(varargin{1})
                in = varargin{1};
                if isfield(in, 'allow_empty_values')
                    allow_empty_values = struct_utils.normalize_bool_scalar( ...
                        in.allow_empty_values, 'allow_empty_values', 'struct_utils:InvalidOptionValue');
                end
                fn = fieldnames(in);
                for ii = 1:numel(fn)
                    key = fn{ii};
                    val = in.(key);
                    if strcmp(key, 'allow_empty_values')
                        continue;
                    end
                    if isfield(opts, key)
                        if allow_empty_values || ~isempty(val)
                            opts.(key) = val;
                        end
                    elseif ~isfield(opts, key)
                        unknown{end+1} = key; %#ok<AGROW>
                    end
                end
                if ~isempty(unknown)
                    unknown = unique(unknown, 'stable');
                    allowed = fieldnames(defaults);
                    error('struct_utils:UnknownOptions', ...
                        'Unknown option field(s): %s (allowed: %s)', ...
                        strjoin(unknown, ', '), strjoin(allowed, ', '));
                end
                return;
            end

            if mod(numel(varargin), 2) ~= 0
                error('struct_utils:InvalidOptions', ...
                    'Options must be a struct or name/value pairs.');
            end
            for ii = 1:2:numel(varargin)
                key = varargin{ii};
                val = varargin{ii + 1};
                if isstring(key) && isscalar(key)
                    key = char(key);
                end
                if ~ischar(key)
                    error('struct_utils:InvalidOptionName', ...
                        'Option names must be char or scalar string.');
                end
                if strcmp(key, 'allow_empty_values')
                    allow_empty_values = struct_utils.normalize_bool_scalar( ...
                        val, 'allow_empty_values', 'struct_utils:InvalidOptionValue');
                    continue;
                end
                if isfield(opts, key)
                    if allow_empty_values || ~isempty(val)
                        opts.(key) = val;
                    end
                else
                    unknown{end+1} = key; %#ok<AGROW>
                end
            end
            if ~isempty(unknown)
                unknown = unique(unknown, 'stable');
                allowed = fieldnames(defaults);
                error('struct_utils:UnknownOptions', ...
                    'Unknown option field(s): %s (allowed: %s)', ...
                    strjoin(unknown, ', '), strjoin(allowed, ', '));
            end
        end
    end
% Owns the small numeric and formatting helpers that are reused across setup and reporting paths.
% These stay lightweight and purpose-first so bigger helpers do not need to repeat them inline.

    methods (Static)
        function x_out = assert_nonnegative_checked(x_in, label)
        % Validate nonnegativity without clamp fallback.

            x_out = x_in;
            if isempty(x_out)
                return;
            end
            finite_mask = isfinite(x_out);
            if any(finite_mask(:))
                vals = x_out(finite_mask);
                vals_real = real(vals);
                vals_imag = imag(vals);
                max_abs = max(abs(vals_real(:)));
                tol = struct_utils.cerupp_numeric_threshold('rel_tol_tight') * max(max_abs, 1);
                max_imag = max(abs(vals_imag(:)));
                if max_imag > tol
                    msg = sprintf('%s: complex leakage detected, max|imag|=%.3e (tol=%.3e).', ...
                        label, max_imag, tol);
                    error('CerUPP:ComplexDiagnosticValues', '%s', msg);
                end
                min_val = min(vals_real(:));
                if min_val < -tol
                    msg = sprintf('%s: negative values detected, min=%.3e (tol=%.3e); no clamp fallback applied.', ...
                        label, min_val, tol);
                    error('CerUPP:NegativeDiagnosticValues', '%s', msg);
                end
            end
        end


        function threshold_value = cerupp_numeric_threshold(threshold_key)
        %CERUPP_NUMERIC_THRESHOLD Shared numeric-threshold catalog.
        % Purpose:
        % - Keep named solver/runtime tolerances in one place.
        % - Avoid duplicated per-file numeric literals drifting over time.

            if nargin < 1 || isempty(threshold_key)
                error('cerupp_numeric_threshold:MissingKey', ...
                    'threshold_key is required.');
            end
            if isstring(threshold_key)
                if ~isscalar(threshold_key)
                    error('cerupp_numeric_threshold:InvalidKeyShape', ...
                        'threshold_key must be a scalar string, not a string array.');
                end
                threshold_key = char(threshold_key);
            elseif ~ischar(threshold_key)
                error('cerupp_numeric_threshold:InvalidKeyType', ...
                    'threshold_key must be char or string; got %s.', class(threshold_key));
            end
            if ~isrow(threshold_key)
                error('cerupp_numeric_threshold:InvalidKeyShape', ...
                    'threshold_key must be a 1xN char row vector.');
            end

            key_norm = lower(strtrim(threshold_key));
            switch key_norm
                case 'rel_tol_tight'
                    threshold_value = 1e-12;
                case 'abs_tol_tiny'
                    threshold_value = 1e-18;
                case 'keldysh_convention_n2_threshold_m2_per_w'
                    threshold_value = 1e-22;
                otherwise
                    error('cerupp_numeric_threshold:UnknownKey', ...
                        'Unknown threshold key "%s".', key_norm);
            end
        end

        function val = conditional_nan_local(v)
        % Convert [] cadence requests into NaN for stored requested-vs-effective metadata.

            if isempty(v)
                val = NaN;
            else
                val = double(v);
            end
        end


        function txt = conditional_note_local(tf, note_txt)
        % Small setup-summary formatter for inherited cadence notes.

            if logical(tf)
                txt = note_txt;
            else
                txt = '';
            end
        end


    end
end
