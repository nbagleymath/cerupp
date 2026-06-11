classdef freeze_hash_utils
%FREEZE_HASH_UTILS Pure-MATLAB SHA-256 and deterministic setup-freeze bytes.

    methods (Static)
        function state = sha256_init()
        %SHA256_INIT Initialize one incremental SHA-256 state.

            state = struct( ...
                'h', uint32([ ...
                    hex2dec('6A09E667'); ...
                    hex2dec('BB67AE85'); ...
                    hex2dec('3C6EF372'); ...
                    hex2dec('A54FF53A'); ...
                    hex2dec('510E527F'); ...
                    hex2dec('9B05688C'); ...
                    hex2dec('1F83D9AB'); ...
                    hex2dec('5BE0CD19')]), ...
                'buffer', uint8([]), ...
                'total_len_bytes', uint64(0));
        end

        function state = sha256_update(state, bytes_in)
        %SHA256_UPDATE Feed bytes into one incremental SHA-256 state.

            if isempty(bytes_in)
                return;
            end

            bytes_in = reshape(uint8(bytes_in), 1, []);
            state.total_len_bytes = state.total_len_bytes + uint64(numel(bytes_in));

            if ~isempty(state.buffer)
                bytes_in = [reshape(state.buffer, 1, []), bytes_in];
                state.buffer = uint8([]);
            end

            full_block_count = floor(numel(bytes_in) / 64);
            for block_idx = 1:full_block_count
                first_idx = 64 * (block_idx - 1) + 1;
                block_bytes = bytes_in(first_idx:(first_idx + 63));
                state.h = freeze_hash_utils.process_block_local(state.h, block_bytes);
            end

            trailing_count = mod(numel(bytes_in), 64);
            if trailing_count > 0
                state.buffer = bytes_in((end - trailing_count + 1):end);
            end
        end

        function hash_hex = sha256_finalize(state)
        %SHA256_FINALIZE Finalize one SHA-256 state and return lowercase hex.

            bit_len = uint64(8) * state.total_len_bytes;
            mod_len = mod(double(state.total_len_bytes) + 1 + 8, 64);
            zero_pad_count = mod(64 - mod_len, 64);
            pad_bytes = [uint8(128), zeros(1, zero_pad_count, 'uint8'), ...
                freeze_hash_utils.uint64_to_be_bytes_local(bit_len)];
            state = freeze_hash_utils.sha256_update(state, pad_bytes);

            if ~isempty(state.buffer)
                error('CerUPP:FreezeHashFinalizeBufferNotEmpty', ...
                    'Internal SHA-256 finalize error: block buffer not empty after padding.');
            end

            digest_bytes = uint8([]);
            for word_idx = 1:numel(state.h)
                digest_bytes = [digest_bytes, ...
                    freeze_hash_utils.uint32_to_be_bytes_local(state.h(word_idx))]; %#ok<AGROW>
            end
            hash_hex = lower(reshape(dec2hex(digest_bytes, 2).', 1, []));
        end

        function hash_hex = sha256_hex_from_bytes(bytes_in)
        %SHA256_HEX_FROM_BYTES Hash one in-memory byte vector.

            state = freeze_hash_utils.sha256_init();
            state = freeze_hash_utils.sha256_update(state, bytes_in);
            hash_hex = freeze_hash_utils.sha256_finalize(state);
        end

        function bytes_out = canonical_serialize_for_hash(value_in)
        %CANONICAL_SERIALIZE_FOR_HASH Deterministic serializer for no-JVM guards.

            bytes_out = freeze_hash_utils.serialize_value_local(value_in);
        end
    end

    methods (Static, Access = private)
        function bytes_out = serialize_value_local(value_in)
            if isnumeric(value_in) || islogical(value_in)
                bytes_out = freeze_hash_utils.serialize_numeric_array_local(value_in);
                return;
            end

            if ischar(value_in)
                raw_bytes = typecast(uint16(value_in(:).'), 'uint8');
                bytes_out = [uint8('|char|'), ...
                    typecast(uint64(size(value_in)), 'uint8'), ...
                    freeze_hash_utils.length_prefix_local(raw_bytes), ...
                    raw_bytes];
                return;
            end

            if isstring(value_in)
                bytes_out = [uint8('|string|'), typecast(uint64(size(value_in)), 'uint8')];
                string_cells = cellstr(value_in);
                for entry_idx = 1:numel(string_cells)
                    entry_bytes = typecast(uint16(string_cells{entry_idx}(:).'), 'uint8');
                    bytes_out = [bytes_out, ...
                        freeze_hash_utils.length_prefix_local(entry_bytes), ...
                        entry_bytes]; %#ok<AGROW>
                end
                return;
            end

            if isa(value_in, 'function_handle')
                bytes_out = freeze_hash_utils.serialize_function_handle_local(value_in);
                return;
            end

            if iscell(value_in)
                bytes_out = [uint8('|cell|'), typecast(uint64(size(value_in)), 'uint8')];
                for entry_idx = 1:numel(value_in)
                    entry_bytes = freeze_hash_utils.serialize_value_local(value_in{entry_idx});
                    bytes_out = [bytes_out, ...
                        freeze_hash_utils.length_prefix_local(entry_bytes), ...
                        entry_bytes]; %#ok<AGROW>
                end
                return;
            end

            if isstruct(value_in)
                field_names = fieldnames(value_in);
                bytes_out = [uint8('|struct|'), ...
                    typecast(uint64(size(value_in)), 'uint8'), ...
                    typecast(uint64(numel(field_names)), 'uint8')];
                for field_idx = 1:numel(field_names)
                    name_bytes = uint8(field_names{field_idx});
                    bytes_out = [bytes_out, ...
                        freeze_hash_utils.length_prefix_local(name_bytes), ...
                        name_bytes]; %#ok<AGROW>
                end
                for entry_idx = 1:numel(value_in)
                    for field_idx = 1:numel(field_names)
                        field_bytes = freeze_hash_utils.serialize_value_local( ...
                            value_in(entry_idx).(field_names{field_idx}));
                        bytes_out = [bytes_out, ...
                            freeze_hash_utils.length_prefix_local(field_bytes), ...
                            field_bytes]; %#ok<AGROW>
                    end
                end
                return;
            end

            if isobject(value_in)
                bytes_out = freeze_hash_utils.serialize_object_local(value_in);
                return;
            end

            if isempty(value_in)
                bytes_out = [uint8('|empty|'), uint8(class(value_in))];
                return;
            end

            error('CerUPP:UnsupportedFreezeHashClass', ...
                'No-JVM setup-freeze hashing does not support class %s.', class(value_in));
        end

        function bytes_out = serialize_numeric_array_local(value_in)
            bytes_out = uint8(class(value_in));
            bytes_out = [bytes_out, uint8([0, double(isreal(value_in))])];
            bytes_out = [bytes_out, typecast(uint64(size(value_in)), 'uint8')];
            flat_value = value_in(:);
            if islogical(flat_value)
                bytes_out = [bytes_out, reshape(uint8(flat_value), 1, [])];
            elseif isreal(flat_value)
                bytes_out = [bytes_out, reshape(typecast(flat_value, 'uint8'), 1, [])];
            else
                bytes_out = [bytes_out, reshape(typecast(real(flat_value), 'uint8'), 1, [])];
                imag_tag = uint8('|imag|');
                bytes_out = [bytes_out, imag_tag, ...
                    reshape(typecast(imag(flat_value), 'uint8'), 1, [])];
            end
        end

        function bytes_out = serialize_function_handle_local(value_in)
            handle_info = functions(value_in);
            handle_info.func2str = func2str(value_in);
            info_bytes = freeze_hash_utils.serialize_value_local(handle_info);
            bytes_out = [uint8('|function_handle|'), ...
                freeze_hash_utils.length_prefix_local(info_bytes), info_bytes];
        end

        function bytes_out = serialize_object_local(value_in)
            class_bytes = uint8(class(value_in));
            property_names = sort(properties(value_in));
            bytes_out = [uint8('|object|'), ...
                freeze_hash_utils.length_prefix_local(class_bytes), class_bytes, ...
                typecast(uint64(size(value_in)), 'uint8'), ...
                typecast(uint64(numel(property_names)), 'uint8')];

            for property_idx = 1:numel(property_names)
                name_bytes = uint8(property_names{property_idx});
                bytes_out = [bytes_out, ...
                    freeze_hash_utils.length_prefix_local(name_bytes), ...
                    name_bytes]; %#ok<AGROW>
            end

            for entry_idx = 1:numel(value_in)
                for property_idx = 1:numel(property_names)
                    property_name = property_names{property_idx};
                    try
                        property_value = value_in(entry_idx).(property_name);
                        property_bytes = freeze_hash_utils.serialize_value_local( ...
                            property_value);
                    catch me_property
                        property_bytes = ...
                            freeze_hash_utils.serialize_opaque_value_local( ...
                                value_in(entry_idx), me_property);
                    end
                    bytes_out = [bytes_out, ...
                        freeze_hash_utils.length_prefix_local(property_bytes), ...
                        property_bytes]; %#ok<AGROW>
                end
            end
        end

        function bytes_out = serialize_opaque_value_local(value_in, me_property)
            class_bytes = uint8(class(value_in));
            error_id_bytes = uint8(me_property.identifier);
            error_message_bytes = typecast(uint16(me_property.message(:).'), 'uint8');
            bytes_out = [uint8('|opaque_object_value|'), ...
                freeze_hash_utils.length_prefix_local(class_bytes), class_bytes, ...
                typecast(uint64(size(value_in)), 'uint8'), ...
                freeze_hash_utils.length_prefix_local(error_id_bytes), ...
                error_id_bytes, ...
                freeze_hash_utils.length_prefix_local(error_message_bytes), ...
                error_message_bytes];
        end

        function prefix = length_prefix_local(bytes_in)
            prefix = typecast(uint64(numel(bytes_in)), 'uint8');
        end

        function h_out = process_block_local(h_in, block_bytes)
            K = uint32([ ...
                hex2dec('428A2F98'); hex2dec('71374491'); hex2dec('B5C0FBCF'); hex2dec('E9B5DBA5'); ...
                hex2dec('3956C25B'); hex2dec('59F111F1'); hex2dec('923F82A4'); hex2dec('AB1C5ED5'); ...
                hex2dec('D807AA98'); hex2dec('12835B01'); hex2dec('243185BE'); hex2dec('550C7DC3'); ...
                hex2dec('72BE5D74'); hex2dec('80DEB1FE'); hex2dec('9BDC06A7'); hex2dec('C19BF174'); ...
                hex2dec('E49B69C1'); hex2dec('EFBE4786'); hex2dec('0FC19DC6'); hex2dec('240CA1CC'); ...
                hex2dec('2DE92C6F'); hex2dec('4A7484AA'); hex2dec('5CB0A9DC'); hex2dec('76F988DA'); ...
                hex2dec('983E5152'); hex2dec('A831C66D'); hex2dec('B00327C8'); hex2dec('BF597FC7'); ...
                hex2dec('C6E00BF3'); hex2dec('D5A79147'); hex2dec('06CA6351'); hex2dec('14292967'); ...
                hex2dec('27B70A85'); hex2dec('2E1B2138'); hex2dec('4D2C6DFC'); hex2dec('53380D13'); ...
                hex2dec('650A7354'); hex2dec('766A0ABB'); hex2dec('81C2C92E'); hex2dec('92722C85'); ...
                hex2dec('A2BFE8A1'); hex2dec('A81A664B'); hex2dec('C24B8B70'); hex2dec('C76C51A3'); ...
                hex2dec('D192E819'); hex2dec('D6990624'); hex2dec('F40E3585'); hex2dec('106AA070'); ...
                hex2dec('19A4C116'); hex2dec('1E376C08'); hex2dec('2748774C'); hex2dec('34B0BCB5'); ...
                hex2dec('391C0CB3'); hex2dec('4ED8AA4A'); hex2dec('5B9CCA4F'); hex2dec('682E6FF3'); ...
                hex2dec('748F82EE'); hex2dec('78A5636F'); hex2dec('84C87814'); hex2dec('8CC70208'); ...
                hex2dec('90BEFFFA'); hex2dec('A4506CEB'); hex2dec('BEF9A3F7'); hex2dec('C67178F2')]);

            W = zeros(64, 1, 'uint32');
            for word_idx = 1:16
                byte_idx = 4 * (word_idx - 1) + 1;
                W(word_idx) = freeze_hash_utils.pack_u32_from_be_bytes_local( ...
                    block_bytes(byte_idx:(byte_idx + 3)));
            end
            for word_idx = 17:64
                s0 = bitxor( ...
                    bitxor( ...
                        freeze_hash_utils.rotr_u32_local(W(word_idx - 15), 7), ...
                        freeze_hash_utils.rotr_u32_local(W(word_idx - 15), 18)), ...
                    bitshift(W(word_idx - 15), -3));
                s1 = bitxor( ...
                    bitxor( ...
                        freeze_hash_utils.rotr_u32_local(W(word_idx - 2), 17), ...
                        freeze_hash_utils.rotr_u32_local(W(word_idx - 2), 19)), ...
                    bitshift(W(word_idx - 2), -10));
                W(word_idx) = freeze_hash_utils.add_u32_local( ...
                    W(word_idx - 16), s0, W(word_idx - 7), s1);
            end

            a = h_in(1);
            b = h_in(2);
            c = h_in(3);
            d = h_in(4);
            e = h_in(5);
            f = h_in(6);
            g = h_in(7);
            h = h_in(8);

            for round_idx = 1:64
                S1 = bitxor( ...
                    bitxor( ...
                        freeze_hash_utils.rotr_u32_local(e, 6), ...
                        freeze_hash_utils.rotr_u32_local(e, 11)), ...
                    freeze_hash_utils.rotr_u32_local(e, 25));
                ch = bitxor(bitand(e, f), bitand(bitcmp(e, 'uint32'), g));
                temp1 = freeze_hash_utils.add_u32_local(h, S1, ch, K(round_idx), W(round_idx));
                S0 = bitxor( ...
                    bitxor( ...
                        freeze_hash_utils.rotr_u32_local(a, 2), ...
                        freeze_hash_utils.rotr_u32_local(a, 13)), ...
                    freeze_hash_utils.rotr_u32_local(a, 22));
                maj = bitxor(bitxor(bitand(a, b), bitand(a, c)), bitand(b, c));
                temp2 = freeze_hash_utils.add_u32_local(S0, maj);

                h = g;
                g = f;
                f = e;
                e = freeze_hash_utils.add_u32_local(d, temp1);
                d = c;
                c = b;
                b = a;
                a = freeze_hash_utils.add_u32_local(temp1, temp2);
            end

            h_out = h_in;
            h_out(1) = freeze_hash_utils.add_u32_local(h_out(1), a);
            h_out(2) = freeze_hash_utils.add_u32_local(h_out(2), b);
            h_out(3) = freeze_hash_utils.add_u32_local(h_out(3), c);
            h_out(4) = freeze_hash_utils.add_u32_local(h_out(4), d);
            h_out(5) = freeze_hash_utils.add_u32_local(h_out(5), e);
            h_out(6) = freeze_hash_utils.add_u32_local(h_out(6), f);
            h_out(7) = freeze_hash_utils.add_u32_local(h_out(7), g);
            h_out(8) = freeze_hash_utils.add_u32_local(h_out(8), h);
        end

        function out = add_u32_local(varargin)
            accum = uint64(0);
            for arg_idx = 1:nargin
                accum = accum + uint64(varargin{arg_idx});
            end
            out = uint32(bitand(accum, uint64(4294967295)));
        end

        function out = rotr_u32_local(x_in, shift_in)
            shift_in = mod(double(shift_in), 32);
            if shift_in == 0
                out = x_in;
                return;
            end
            out = bitor(bitshift(x_in, -shift_in), bitshift(x_in, 32 - shift_in));
        end

        function word_out = pack_u32_from_be_bytes_local(bytes_in)
            bytes_in = uint32(bytes_in);
            word_out = bitor( ...
                bitor(bitshift(bytes_in(1), 24), bitshift(bytes_in(2), 16)), ...
                bitor(bitshift(bytes_in(3), 8), bytes_in(4)));
        end

        function bytes_out = uint32_to_be_bytes_local(word_in)
            bytes_out = typecast(uint32(word_in), 'uint8');
            bytes_out = bytes_out(end:-1:1);
        end

        function bytes_out = uint64_to_be_bytes_local(word_in)
            bytes_out = typecast(uint64(word_in), 'uint8');
            bytes_out = bytes_out(end:-1:1);
        end
    end
end
