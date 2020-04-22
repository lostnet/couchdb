% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(aegis_noop_key_manager).


-behaviour(aegis_key_manager).


-export([
    init_db/2,
    open_db/2
]).


init_db(#{} = _Db, _Options) ->
    false.


open_db(#{} = _Db, _Options) ->
    false.
