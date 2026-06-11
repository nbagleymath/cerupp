classdef compat_utils
%COMPAT_UTILS Small MATLAB-release compatibility wrappers used by CerUPP.

    methods (Static)
        function tf = isfile_compat(path_in)
        %ISFILE_COMPAT Backward-compatible file-existence check.

            if exist('isfile', 'builtin') || exist('isfile', 'file')
                tf = isfile(path_in);
                return;
            end

            if isstring(path_in)
                if isscalar(path_in)
                    path_in = char(path_in);
                else
                    path_in = cellstr(path_in);
                end
            end

            if iscell(path_in)
                tf = false(size(path_in));
                for entry_idx = 1:numel(path_in)
                    tf(entry_idx) = compat_utils.isfile_compat(path_in{entry_idx});
                end
                return;
            end

            if ~ischar(path_in)
                error('CerUPP:CompatInvalidPathInput', ...
                    'isfile_compat expects a char, string, or cell array of paths.');
            end

            listing = dir(path_in);
            tf = ~isempty(listing) && ~listing(1).isdir;
        end

        function write_matrix_csv_compat(matrix_data, csv_path)
        %WRITE_MATRIX_CSV_COMPAT Backward-compatible numeric CSV writer.

            if exist('writematrix', 'builtin') || exist('writematrix', 'file')
                writematrix(matrix_data, csv_path);
                return;
            end

            if ~(isnumeric(matrix_data) || islogical(matrix_data)) || (ndims(matrix_data) > 2)
                error('CerUPP:CompatCsvUnsupportedMatrix', ...
                    'R2016b CSV fallback only supports 2-D numeric/logical matrices.');
            end

            dlmwrite(csv_path, matrix_data, 'delimiter', ',', 'precision', '%.15g');
        end
    end
end
