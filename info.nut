class TeshiNet extends AIInfo
{
    function GetAuthor()      { return "Teshiron"; }
    function GetName()        { return "TeshiNet"; }
    function GetDescription() { return "An AI primarily using road vehicles, can transport most types of cargo."; }
    function GetVersion()     { return 5; }
    function MinVersionToLoad() { return 4; }
    function GetDate()        { return "2011-12-15"; }
    function CreateInstance() { return "TeshiNet"; }
    function GetShortName()   { return "TESH"; }
    function GetAPIVersion()  { return "1.1"; }

    function GetSettings()
    {
        AddSetting({name = "log_level", description = "Log level", min_value = 1, max_value = 3, easy_value = 1, medium_value = 1, hard_value = 1, custom_value = 1, flags = AICONFIG_INGAME});
        AddLabels("log_level", {_1 = "Info only", _2 = "More verbose", _3 = "All messages (debug)"});
        AddSetting({name = "play_nicely", description = "Play nicely (if we have an awarded subsidy, do not seek another)", easy_value = 1, medium_value = 1, hard_value = 0, custom_value = 0, flags = AICONFIG_BOOLEAN | AICONFIG_INGAME});
        AddSetting({name = "enable_buses", description = "Enable buses (if disabled, trucks & planes only)", easy_value = 1, medium_value = 1, hard_value = 1, custom_value = 1, flags = AICONFIG_BOOLEAN | AICONFIG_INGAME});
        //AddSetting({name = "use_rvs", description = "Enable road vehicles", easy_value = 1, medium_value = 1, hard_value = 1, custom_value = 1, flags = AICONFIG_BOOLEAN | AICONFIG_INGAME});
        AddSetting({name = "use_planes", description = "Enable aircraft", easy_value = 1, medium_value = 1, hard_value = 1, custom_value = 1, flags = AICONFIG_BOOLEAN | AICONFIG_INGAME});
        //AddSetting({name = "use_trains", description = "Enable trains", easy_value = 1, medium_value = 1, hard_value = 1, custom_value = 1, flags = AICONFIG_BOOLEAN | AICONFIG_INGAME});
        //AddSetting({name = "use_ships", description = "Enable ships", easy_value = 1, medium_value = 1, hard_value = 1, custom_value = 1, flags = AICONFIG_BOOLEAN | AICONFIG_INGAME});
    }
}

RegisterAI(TeshiNet());
