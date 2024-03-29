function add_experiments_to_db(start_time, parameters)
    % Add expeirmental information automatically to the DB
    %
    % This function can be called with 2 arguments or with none.
    % 1. When called with 2 arguments it allways adds the calling function
    % (whoever called add_expeirments_to_db) to global variable
    % expeirments_list. Depending on calling function, it might also
    % trigger sending info to the DB
    % 2. When called with no arguments it just triggers sending the
    % information in global variable 'experiments_list' to the db
    % 
    % How to use it:
    %   1. somewhere before your stimulus starts call something like this:
    %       start_t = datestr(now, 'HH:MM:SS');
    %       ...
    %       Your stimulus goes in here
    %       After your stimulus is done
    %       ...
    %       add_experiments_to_db(start_t, [parameters, varargin])
    %   
    %      where arguments = {req_arg_1, req_arg_2, ..., req_arg_n}
    %
    % Example
    %      function mystim(length, checker_size, varargin)
    %        ...
    %        start_t = datestr(now, 'HH:MM:SS');
    %        parameters = {length, checker_size}
    %        ...
    %        add_experiments_to_db(start_t, [parameters, varargin]);            
        
    % Sending information to the DB is achieved through 
    % add_experiment_to_db(stimulus, start_time,
    % end_time, parameters) (not "experiment" is singular) and is defined
    % below
    %
    % When calling add_experiment_to_db it will get parameter 'stimulus' from
    % the dbstack (function that called add_experiments_to_db) and 
    % 'end_time' from now().
    global experiments_list

    if ~(nargin==0 || nargin==2)
        error('add_experiments_to_db should be called with 0 or 2 parameters');
    end
    
    s = dbstack('-completenames');
    
    % although this function has 3 parameters, it might be called with no
    % parameters only to force sending experiments_list to the DB
    if (nargin)
        end_t = datestr(now, 'HH:MM:SS');
        stimulus = s(2).name;
%        stimulus = stimulus.name
 
        experiments_list{end+1} = {stimulus, start_time, end_t, parameters};
    end
    
    if size(s,1)==2
        % now it is the time to send everything to the DB 
        prompt = {'Your db name (do not use root)', 'password'};
        default = {'', 'ganglion'};
        user = '';
        while 1
            while strcmp(user, 'root') || strcmp(user, '')
                input = inputdlg(prompt, 'DB info', 1, default);
                
                if isempty(input)
                    % user pressed cancel, probably doesn't want to send exp to DB
                    % database connection will fail bellow and will get
                    % prompted whether to quit for real
                    password = '-1';
                    break;
                end
                user = input{1};
                password = input{2};
            end
            
            dbname = 'test';
            % Try to connect to the db with the given name and password
            conn = database(dbname, user, password, 'Vendor', 'MySQL');
            
            % if connection failed, ask whether to try again
            if isconnection(conn)
                % get out of this forever loop and write data to DB
                break
            else
                answer = questdlg('Couldn''t connect to db. Do you want to try again?', ...
                    'Error connecting to DB', 'Yes', 'No', 'Yes')
            end
            
            if strcmp(answer, 'No')
                % clean experiments_list and return
                clear experiments_list
                return
            else
                user = '';
                password = '';
            end
        end
        for i=1:length(experiments_list)
            add_experiment_to_db(conn, experiments_list{i})
        end
        
        clear experiments_list

        % Update monitor configuration if needed
        add_monitor_settings(conn);

        close(conn);
    end        
end

function add_experiment_to_db(conn, db_params)
    % Add the given experiments with all associated parameters to the
    % database. 
    % 
    % Two different important cases should be handled
    % 1. When the user is running an experiment that is used frequently (RF
    % that is already in the db.stimuli table. In that case 'stim_id' is
    % the 'stimuli' table id
    % 2. When the user is running an experiment that is not included in the
    % db, in that case stimulus_id is -1
    %
    % parameters:
    %   conn = database('db_name','user','password','Vendor','MySQL');
    %
    %   db_params:  cell array with the following items
    %       db_params{1}:   stimulus = 'RF'
    %
    %       db_params{2}:   start_time = '15:59:30'
    %
    %       db_params{3}:   end_time = '17:03:04'
    %
    %       db_params{4}:   parameters:     a cell array
    
    stimulus = db_params{1};
    start_time = db_params{2};
    end_time = db_params{3};
    parameters = db_params{4};
    
    stimulus_id = get_stimulus_id(conn, stimulus);
    
    user = get(conn, 'UserName');

    date = datestr(today, 'yyyy-mm-dd');
    start_time = datestr(start_time, 'HH:MM:SS');
    end_time = datestr(end_time, 'HH:MM:SS');
    params = parameters_to_text(parameters);
    
    % if 'stimulus' is not in the 'stimuli' table, the name of the
    % experiment will be lost. Instead I'm just adding it to the parameters
    % list at the beginning
    if stimulus_id==-1
        params = [stimulus, ', ', params];
    end
    

    columns = {'stimulus_id', 'user', 'date', 'start_time', 'end_time', 'params'};
    values = {stimulus_id, user, date, start_time, end_time, params};

    insert(conn, 'experiments', columns, values)
end

function stimulus_id = get_stimulus_id(conn, stimulus)
    % Get the stimulus ID associated wtih stimulus (if more than one, use
    % the one with the largest version)
    sql = ['SELECT id FROM stimuli WHERE NAME=''', stimulus, ''' ORDER BY version DESC;'];
    cur = exec(conn, sql);
    cur = fetch(cur, 1);
    stimulus_id = cur.Data{1};
    
    if ischar(stimulus_id)
        stimulus_id = -1;
    end
end


function params = parameters_to_text(parameters)
    params = '';
    for i = 1:length(parameters)
        if ischar(parameters{i})
            params = [params, parameters{i}];
        elseif isnumeric(parameters{i})
            params = [params, mat2str(parameters{i})];
        else
            error('add_experiment_to_db can''t convert one parameter to text');
        end
        
        if i<length(parameters)
            params = [params, ', '];
        end
        
    end
end

function add_monitor_settings(conn)
    % pull the last monitor settings from the DB and if either nominal rate
    % or resolution changed, update the DB
    cur = exec(conn, 'SELECT width, height, nominal_rate, pixel_size FROM monitor ORDER BY date DESC;');
    data = fetch(cur, 1);
    width = data.Data{1};
    height = data.Data{2};
    nominal_rate = data.Data{3};
    pixel_size = data.Data{4};
    
    % get nominal rate
    screen = max(Screen('Screens'));
    new = Screen('Resolution', screen);
    
    if new.hz ~= nominal_rate || ...
            new.width ~= width || ...
            new.height ~= height || ...
            new.pixelSize ~= pixel_size
        insert(conn, 'monitor', {'width', 'height', 'pixel_size', 'nominal_rate'}, ...
            {new.width, new.height, new.pixelSize, new.hz});
    end
end
