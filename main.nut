import("util.superlib", "SuperLib", 38); // Import SuperLib version 38
import("Queue.Priority_Queue", "Priority_Queue", 2); //import PriorityQueue

Helper <- SuperLib.Helper;
Tile <- SuperLib.Tile;
Log <- SuperLib.Log;
Money <- SuperLib.Money;
SLRoadPathFinder <- SuperLib.RoadPathFinder;
RoadBuilder <- SuperLib.RoadBuilder;
Road <- SuperLib.Road;
Result <- SuperLib.Result;
Station <- SuperLib.Station;
Direction <- SuperLib.Direction;

require("cargo.nut");
require("planes.nut");

class TeshiNet extends AIController
{
    towns_used = null;
    industries_used = null;
    passenger_cargo_id = null;
    goods_cargo_id = null;
    mail_cargo_id = null;
    last_route_tick = -1000; //begin constructing a new route immediately
    last_loan_pmt_tick = 10000;
    station_depot_pairs = null;
    last_route_manage_tick = 0;
    station_pairs = null;
    last_dead_station_check = 0;
    at_max_RV_count = null;
    at_max_plane_count = null;
    cargo_list = null;
    last_cargo = null;
    last_route_type = null;
    last_unprof_route_check = 0;
    last_air_route = -1200;
    last_plane_check = 1000;
    disable_buses = false;
    event_queue = null;
    stations_by_industry = null;
    industries_by_station = null;
    last_upgrade_search = 0;

    constructor()
    {
        Log.Info("Calling constructor.", Log.LVL_DEBUG);
        this.towns_used = AIList();
        this.industries_used = AIList();
        this.station_depot_pairs = AIList();
        this.station_pairs = AIList();
        this.at_max_RV_count = false;
        this.cargo_list = AICargoList();
        this.event_queue = Priority_Queue();
        this.stations_by_industry = AIList();
        this.industries_by_station = AIList();

        local list = AICargoList();

        this.passenger_cargo_id = Helper.GetPAXCargo();
        Log.Info("Passenger cargo has been identified as " + AICargo.GetCargoLabel(this.passenger_cargo_id), Log.LVL_DEBUG);

        for (local i = list.Begin(); list.HasNext(); i = list.Next())
        {
            if (AICargo.HasCargoClass(i, AICargo.CC_MAIL) && (AICargo.GetTownEffect(i) == AICargo.TE_MAIL))
            {
                this.mail_cargo_id = i;
                break;
            }
        }

        for (local i = list.Begin(); list.HasNext(); i = list.Next())
        {
            if (AICargo.GetTownEffect(i) == AICargo.TE_GOODS)
            {
                this.goods_cargo_id = i;
                break;
            }
        }

        this.cargo_list.RemoveValue(this.passenger_cargo_id);
        this.cargo_list.RemoveValue(this.mail_cargo_id);
        this.cargo_list.Valuate(AICargo.GetCargoIncome, 10, 100);
        this.cargo_list.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_DESCENDING);

        Log.Info("Constructor completed.", Log.LVL_DEBUG);
    }
}

function TeshiNet::Start()
{
    Log.Info("TeshiNet v4.0.3 Loaded", Log.LVL_INFO);

    if (this.towns_used.IsEmpty()) SetCompanyName();

    AICompany.SetAutoRenewStatus(true);
    AICompany.SetAutoRenewMoney(20000);
    AICompany.SetAutoRenewMonths(-6);

    //Main loop.

    while (true) //Keep running. If Start() exits, the AI dies.
    {
        local skipNewRoute = false;
        local skipPlaneRoute = false;

        if (AIController.GetSetting("use_planes") == 0)
        {
            skipPlaneRoute = true;
        }

        if (AIController.GetSetting("enable_buses") == 0)
        {
            this.disable_buses = true;
        }
        else
        {
            this.disable_buses = false;
        }

        while (AIEventController.IsEventWaiting()) //Event handler: get relevant events and queue them up for handling, by priority
        {
            local event = AIEventController.GetNextEvent();
            switch (event.GetEventType())
            {
                case AIEvent.AI_ET_INDUSTRY_CLOSE:
                    local closeEvent = AIEventIndustryClose.Convert(event);
                    local closedInd = closeEvent.GetIndustryID();
                    if (this.stations_by_industry.HasItem(closedInd))
                    {
                        this.event_queue.Insert(event, 3);
                        Log.Info("Queued an industry closure.", Log.LVL_DEBUG);
                    }
                    break;

                case AIEvent.AI_ET_VEHICLE_UNPROFITABLE:
                    this.event_queue.Insert(event, 5);
                    Log.Info("Queued an unprofitable vehicle notification.", Log.LVL_DEBUG);
                    break;

                case AIEvent.AI_ET_VEHICLE_CRASHED:
                    this.event_queue.Insert(event, 1);
                    Log.Info("Queued a vehicle crash.", Log.LVL_DEBUG);
                    break;

                case AIEvent.AI_ET_VEHICLE_WAITING_IN_DEPOT:
                    this.event_queue.Insert(event, 7);
                    Log.Info("Queued a vehicle waiting in depot.", Log.LVL_DEBUG);
                    break;

                default:
                    break;
            }
        }

        if (this.towns_used.IsEmpty() && this.industries_used.IsEmpty()) //get a loan if we're a new company
        {
            Log.Info("Setting loan to max loan for startup cash.", Log.LVL_SUB_DECISIONS);
            local tmp = AICompany.GetMaxLoanAmount();
            AICompany.SetMinimumLoanAmount(tmp.tointeger());
        }

        if (this.event_queue.Count() > 0)
        {
            skipNewRoute = true; //do not build a new route with queued events -- new vehicles may mess up events
            skipPlaneRoute = true;
        }

        if (this.at_max_RV_count) //if we've run out of road vehicles, remove the least profitable road route
        {
            RemoveLeastProfRoadRoute();
            RemoveUnprofitableRoadRoute();
            SellUnusedVehicles();
            this.at_max_RV_count = false;
            this.last_unprof_route_check = this.GetTick();
            skipNewRoute = true; //if we've just run out of vehicles, don't build a new route, to allow vehicle slack for improvements

        }

        if (this.at_max_plane_count) //if we've run out of planes, remove the least profitable air route
        {
            Planes.SellStoppedPlanes();
            Planes.RemoveUnprofRoute();
            this.at_max_plane_count = false;
            skipPlaneRoute = true; //same as above
        }

        if (this.GetTick() > (this.last_route_manage_tick + 1400) && (AICompany.GetBankBalance(AICompany.COMPANY_SELF) > 50000))
        {
            if (this.event_queue.Count() > 0)
            {
                Log.Info("No route management while queued events are pending.", Log.LVL_INFO); //building new vehicles will mess up events
            }
            else
            {
                Log.Info("Managing existing routes.", Log.LVL_INFO);
                Cargo.ManageBusyTruckStations();
                ManageBusyBusStations();
                Planes.ManageBusyAirports();
                this.last_route_manage_tick = this.GetTick();
            }
        }

        //Build a new road route if there's enough cash.
        if (AICompany.GetBankBalance(AICompany.COMPANY_SELF) > 50000 && this.GetTick() > (this.last_route_tick + 1000))
        {
            if (!skipNewRoute)
            {
                NewRoadRoute();
            }
        }


        //build a new plane route if there's enough cash
        if (AICompany.GetBankBalance(AICompany.COMPANY_SELF) > 500000 && this.GetTick() > (this.last_air_route + 5000))
        {
            if (!skipPlaneRoute)
            {
                local ret = Planes.BuildAirRoute();
                if (ret != -1) this.last_air_route = this.GetTick();
            }
        }

        if (this.GetTick() > (this.last_plane_check + 1250))
        {
            //TODO: find planes with only one order and remove the airport -- the route was not built right.
            Planes.RemoveUnprofPlanes();
            Planes.SellStoppedPlanes();
            this.last_plane_check = this.GetTick();
        }

        if (this.GetTick() > (this.last_loan_pmt_tick + 1850)) //pay off loan .
        {
            local tempList = AIStationList(AIStation.STATION_ANY);
            if (tempList.Count() > 30)
            {
                if (AICompany.GetBankBalance(AICompany.COMPANY_SELF) > (2 * AICompany.GetLoanInterval()))
                {
                    if (AICompany.GetLoanAmount() != 0)
                    {
                        if (AICompany.GetBankBalance(AICompany.COMPANY_SELF) >= (2 * AICompany.GetLoanAmount()))
                        {
                            Log.Info("We have more than 2x our loan in the bank. Paying off our loan in full.", Log.LVL_INFO);
                            AICompany.SetLoanAmount(0);
                            this.last_loan_pmt_tick = this.GetTick();
                        }
                        else
                        {
                            Log.Info("Making a loan payment.", Log.LVL_INFO);
                            AICompany.SetLoanAmount(AICompany.GetLoanAmount() - AICompany.GetLoanInterval());
                            this.last_loan_pmt_tick = this.GetTick();
                       }
                    }
                    else
                    {
                        Log.Info("We have no loan.", Log.LVL_DEBUG);
                        this.last_loan_pmt_tick = this.GetTick();
                    }
                }
                else
                {
                    Log.Warning("Not enough money for a loan payment.", Log.LVL_INFO);
                    this.last_loan_pmt_tick = this.GetTick() + 7000; //allow more time for the company to grow
                }
            }
            else
            {
                Log.Info("Less than 15 routes in place, no loan payment at this time.", Log.LVL_INFO);
                this.last_loan_pmt_tick = this.GetTick();
            }
        }

        if (this.GetTick() > this.last_dead_station_check + 2500)
        {
            SellUnusedVehicles();
            RemoveDeadRoadStations();
            Planes.RemoveUnusedAirports();
            this.last_dead_station_check = this.GetTick();
        }

        if (this.GetTick() > this.last_upgrade_search + 15000)
        {
            UpgradeRoadVehicles();
            //Planes.UpgradePlanes(); (not implemented yet)
            this.last_upgrade_search = this.GetTick();
        }

        //Handle a queued event
        if (this.event_queue.Count() > 0)
        {
            EventHandler();
        }

        Log.Info("End of main loop: tick " + this.GetTick(), Log.LVL_DEBUG);

        this.Sleep(50);
    }
}

function TeshiNet::Stop()
{
}

function TeshiNet::Save()
{
    Log.Info("Saving data...", Log.LVL_DEBUG);
    local savedata = {};
    local townsused = [];
    local industriesused = [];
    local sta_dep_pairs = {};
    local sta_pairs = {};
    local sta_by_ind = {};
    local ind_by_sta = {};

    for (local x = this.towns_used.Begin(); this.towns_used.HasNext(); x = this.towns_used.Next())
    {
        townsused.push(x);
    }

    for (local x = this.industries_used.Begin(); this.industries_used.HasNext(); x = this.industries_used.Next())
    {
        industriesused.push(x);
    }

    for (local y = this.station_depot_pairs.Begin(); this.station_depot_pairs.HasNext(); y = this.station_depot_pairs.Next())
    {
        sta_dep_pairs.rawset(y, this.station_depot_pairs.GetValue(y));
    }

    for (local z = this.station_pairs.Begin(); this.station_pairs.HasNext(); z = this.station_pairs.Next())
    {
        sta_pairs.rawset(z, this.station_pairs.GetValue(z));
    }

    for (local q = this.industries_by_station.Begin(); this.industries_by_station.HasNext(); q = this.industries_by_station.Next())
    {
        ind_by_sta.rawset(q, this.industries_by_station.GetValue(q));
    }

    for (local p = this.stations_by_industry.Begin(); this.stations_by_industry.HasNext(); p = this.stations_by_industry.Next())
    {
        sta_by_ind.rawset(p, this.industries_by_station.GetValue(p));
    }

    savedata.rawset("townsused", townsused);
    savedata.rawset("industriesused", industriesused);
    savedata.rawset("sta_dep_pairs", sta_dep_pairs);
    savedata.rawset("sta_pairs", sta_pairs);
    savedata.rawset("last_cargo", this.last_cargo);
    savedata.rawset("last_route_type", last_route_type);
    savedata.rawset("sta_by_ind", sta_by_ind);
    savedata.rawset("ind_by_sta", ind_by_sta);

    Log.Info("Done!", Log.LVL_DEBUG);
    return savedata;
}

function TeshiNet::Load(version, data)
{
    Log.Info("Loading saved data...", Log.LVL_INFO);

    Log.Info("Loading towns serviced...", Log.LVL_DEBUG);
    this.towns_used = AIList();

    foreach (x in data.rawget("townsused"))
    {
        this.towns_used.AddItem(x, 1);
    }

    Log.Info("Loading industries used...", Log.LVL_DEBUG);

    if (data.rawin("industriesused"))
    {
        foreach (g in data.rawget("industriesused"))
        {
            this.industries_used.AddItem(g, 1);
        }
    }

    Log.Info("Loading station/depot pairings...", Log.LVL_DEBUG);
    this.station_depot_pairs = AIList();

    local sta_dep_pairs = {};

    sta_dep_pairs = data.rawget("sta_dep_pairs");

    foreach (x, y in sta_dep_pairs)
    {
        this.station_depot_pairs.AddItem(x, y);
    }

    Log.Info("Loading station route pairs...", Log.LVL_DEBUG);
    this.station_pairs = AIList();

    local sta_pairs = {};

    sta_pairs = data.rawget("sta_pairs");

    foreach (a, b in sta_pairs)
    {
        this.station_pairs.AddItem(a, b);
    }

    if (data.rawin("sta_by_ind"))
    {
        local sta_by_ind = data.rawget("sta_by_ind");
        foreach (t, r in sta_by_ind)
        {
            this.stations_by_industry.AddItem(t, r);
        }
    }

    if (data.rawin("ind_by_sta"))
    {
        local ind_by_sta = data.rawget("ind_by_sta");
        foreach (p, q in ind_by_sta)
        {
            this.industries_by_station.AddItem(p, q);
        }
    }

    if (data.rawin("last_cargo")) this.last_cargo = data.rawget("last_cargo");
    if (data.rawin("last_route_type")) this.last_route_type = data.rawget("last_route_type");

    Log.Info("Done.", Log.LVL_INFO);
}


function TeshiNet::SetCompanyName()
{
    if(!AICompany.SetName("TeshiNet"))
    {
        local i = 2;
        while (!AICompany.SetName("TeshiNet #" + i))
        {
            i = i + 1;
            if(i > 255) break;
        }
    }
}

function TeshiNet::NewRoadRoute()
{
    Log.Info("Constructing a new road route.", Log.LVL_INFO);

    //Look for a subsidy
    local mySubsidy = SelectSubsidy();
    local startIdx = AISubsidy.GetSourceIndex(mySubsidy);
    local destIdx = AISubsidy.GetDestinationIndex(mySubsidy);
    local townPair = null;
    local indPair = null;

    if (AISubsidy.IsValidSubsidy(mySubsidy))
    {
        local cargoType = AISubsidy.GetCargoType(mySubsidy)

        if (cargoType == this.passenger_cargo_id)
        {
            local result = BuildPassengerRoute(startIdx, destIdx);
            if (result == -2)
            {
                this.towns_used.AddItem(startIdx, 1);
                this.towns_used.AddItem(destIdx, 2);
            }
            else
            {
                this.last_route_type = this.passenger_cargo_id;
            }
        }
        else
        {
            Cargo.BuildCargoRoute(startIdx, destIdx, cargoType);
        }
    }
    else
    {
        if (!disable_buses)
        {
            if (this.last_route_type != this.passenger_cargo_id)
            {
                Log.Info("Looking for two towns to connect.", Log.LVL_SUB_DECISIONS);
                townPair = GetPassengerTownPair();
                if (townPair == -1)
                {
                    return -1;
                }

                if (!this.towns_used.HasItem(townPair[0]) && !this.towns_used.HasItem(townPair[1]))
                {
                    Log.Info("Found a suitable town pair. Building route.", Log.LVL_SUB_DECISIONS);
                    BuildPassengerRoute(townPair[0], townPair[1]);
                    this.last_route_type = this.passenger_cargo_id;
                }
                else
                {
                    Log.Warning("No suitable towns found this round. Will try again next loop.", Log.LVL_SUB_DECISIONS);
                }
            }
            else
            {
            Log.Info("Looking for an industry pair.", Log.LVL_SUB_DECISIONS);
                indPair = GetIndustryPair();
                if (indPair == -1)
            {
                return -1;
            }
            Log.Info("Found a suitable industry pair, building route.", Log.LVL_SUB_DECISIONS);
            Cargo.BuildCargoRoute(indPair[0], indPair[1], indPair[2]);
            this.last_route_type = indPair[2];
            }
        }
        else
        {
        Log.Info("Looking for an industry pair.", Log.LVL_SUB_DECISIONS);
        indPair = GetIndustryPair();
        if (indPair == -1)
        {
            return -1;
        }
        Log.Info("Found a suitable industry pair, building route.", Log.LVL_SUB_DECISIONS);
        Cargo.BuildCargoRoute(indPair[0], indPair[1], indPair[2]);
        this.last_route_type = indPair[2];
    }
    }
}

function TeshiNet::SelectSubsidy()
{
    Log.Info("Looking for a subsidy.", Log.LVL_SUB_DECISIONS);
    local cargoOnly = null;

    if (disable_buses)
    {
        cargoOnly = true;
    }
    else
    {
        cargoOnly = false;
    }

    //Pull the current subsidy list.
    local subsList = AISubsidyList();

    //abort immediately if there are no subsidies
    if (subsList.IsEmpty())
    {
        Log.Info("No subsidies currently exist.", Log.LVL_SUB_DECISIONS);
        return -1;
    }

    //Let's check the awarded passenger subsidies, if any belong to us, we abort. (don't care about multiple industry subs right now)
    subsList.Valuate(AISubsidy.IsAwarded);
    subsList.KeepValue(1);
    subsList.Valuate(AISubsidy.GetCargoType);
    subsList.KeepValue(this.passenger_cargo_id);

    for (local curSub = subsList.Begin(); subsList.HasNext(); curSub = subsList.Next())
    {
        local awardCo = AISubsidy.GetAwardedTo(curSub);

        if (AICompany.IsMine(awardCo))
        {
            Log.Info("We already have an awarded passenger subsidy.", Log.LVL_DEBUG);
            cargoOnly = true;
        }
    }

    subsList=AISubsidyList(); //repopulate the list

    //now we keep only the available subs
    subsList.Valuate(AISubsidy.IsAwarded);
    subsList.KeepValue(0);

    //randomize the subsidy list so we're not always competing against other TeshiNet instances
    //if we do not randomize the list, we will always try the subs in order from bottom to top (as listed in the GUI subs window)
    subsList.Valuate(AIBase.RandItem);
    subsList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING);

    for (local currentSub = subsList.Begin(); subsList.HasNext(); currentSub = subsList.Next())
    {
        local source = AISubsidy.GetSourceIndex(currentSub);
        local dest = AISubsidy.GetDestinationIndex(currentSub);
        local sourceTile = null;
        local destTile = null;
        local cargo = AISubsidy.GetCargoType(currentSub);
        local distance = null;

        //check to see if we already serve both source and destination. if so, do not use this one.
        //this avoids building duplicate service to try to get a subsidy if our vehicles are very slow

        Log.Info("Source is " + source + " and destination is " + dest, Log.LVL_DEBUG);

        local maxDist = null;
    local curYear = AIDate.GetYear(AIDate.GetCurrentDate());

        if (cargo == this.passenger_cargo_id)
        {
            Log.Info("Evaluating a passenger subsidy: " + currentSub, Log.LVL_DEBUG);

            if (cargoOnly)
            {
                Log.Info("We already have a passenger sub. Skipping.", Log.LVL_DEBUG);
                continue;
            }

            //TODO: make this check if this pairing is actually a route; if it is not, we should build this subsidy anyway
            if (this.towns_used.HasItem(source) && this.towns_used.HasItem(dest)) //check if we serve both towns
            {
                continue;
            }

            Log.Info("Found a subsidy!", Log.LVL_SUB_DECISIONS);
            return currentSub;

        }
        else
        {
            Log.Info("Evaluating an industry subsidy: " + currentSub, Log.LVL_DEBUG);

            if (AIIndustry.IsBuiltOnWater(source) || AIIndustry.IsBuiltOnWater(dest))
            {
                Log.Info("Either the source or the destination is on water. Skipping.", Log.LVL_DEBUG);
                continue; //we're doing road vehicles; this should be obvious.
            }

            if (this.industries_used.HasItem(source) && this.industries_used.HasItem(dest)) //check if we serve both industries
            {
                continue;
            }

            if (cargo == this.goods_cargo_id || cargo == this.mail_cargo_id)
            {
                Log.Info("Cargo type is delivered to a town, which our route construction cannot handle. Skipping.", Log.LVL_DEBUG);
                continue;
            }

            Log.Info("Found a subsidy!", Log.LVL_SUB_DECISIONS);
            return currentSub;
        }
    }
    Log.Info("Failed to find a subsidy.", Log.LVL_SUB_DECISIONS);
    return -1;
}

function TeshiNet::BuildPassengerRoute(townStart, townEnd)
{

    //Find a place for the source station
    AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);


    local townStartTile = AITown.GetLocation(townStart);
    local townEndTile = AITown.GetLocation(townEnd);

    local startStationTile = -1;
    local endStationTile = -1;
    local startDepotTile = -1;
    local endDepotTile = -1;

    //Use SuperLib to construct stations and depots.
    local startReturn = Road.BuildMagicDTRSInTown(townStart, AIRoad.ROADVEHTYPE_BUS, 1);
    local endReturn = Road.BuildMagicDTRSInTown(townEnd, AIRoad.ROADVEHTYPE_BUS, 1);

    local startStationID = startReturn.station_id ? startReturn.station_id : -1;
    local endStationID = endReturn.station_id ? endReturn.station_id : -1;
    startDepotTile = startReturn.depot_tile;
    endDepotTile = endReturn.depot_tile;

    //Did they both actually get built?
    if (AIStation.IsValidStation(startStationID) && AIStation.IsValidStation(endStationID))
    {
        startStationTile = AIStation.GetLocation(startStationID);
        endStationTile = AIStation.GetLocation(endStationID);
    }
    else
    {
        Log.Error("One or more stations or depots were not built. Aborting.", Log.LVL_INFO); //if not, remove what did get built
        if (AIStation.IsValidStation(startStationID))
        {
            Station.DemolishStation(startStationID);
        }
        if (AIStation.IsValidStation(endStationID))
        {
            Station.DemolishStation(endStationID);
        }
        if (startDepotTile) AIRoad.RemoveRoadDepot(startDepotTile);
        if (endDepotTile) AIRoad.RemoveRoadDepot(endDepotTile);
        return -1;
    }

    //Now, pathfind and build.
    local builder = RoadBuilder();

    builder.Init(startStationTile, endStationTile);
    local pathResult = builder.ConnectTiles();

    //Did it work?
    if (pathResult != 0)
    {
        Log.Error("Unable to connect stations. Aborting and removing stations.", Log.LVL_INFO);
        Station.DemolishStation(AIStation.GetStationID(startStationTile));
        Station.DemolishStation(AIStation.GetStationID(endStationTile));
        AIRoad.RemoveRoadDepot(startDepotTile);
        AIRoad.RemoveRoadDepot(endDepotTile);
        return -1
    }

    //Now that the path is built, let's build some vehicles.
    Log.Info("Buying vehicles.", Log.LVL_SUB_DECISIONS);
    local useDepot = startDepotTile;

    //We need to figure out which type of bus to buy.

    local vehList = AIEngineList(AIVehicle.VT_ROAD);

    //only the buildable engines
    vehList.Valuate(AIEngine.IsBuildable);
    vehList.KeepValue(1);

    //and only road buses, not trams

    vehList.Valuate(AIEngine.GetRoadType);
    vehList.KeepValue(AIRoad.ROADTYPE_ROAD);

    //now, only buses
    vehList.Valuate(AIEngine.GetCargoType);
    vehList.KeepValue(this.passenger_cargo_id);

    //No articulated buses.
    vehList.Valuate(AIEngine.IsArticulated);
    vehList.KeepValue(0);

    //we want the fastest type of bus.
    vehList.Valuate(AIEngine.GetMaxSpeed);
    vehList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_DESCENDING);

    local busType = vehList.Begin(); //we'll build the one at the top of the list.
    local buses = [];

    buses.insert(0, AIVehicle.BuildVehicle(useDepot, busType)); //build one bus of the right type in the desired depot

    if (!AIVehicle.IsValidVehicle(buses[0]))
    {
        local errorCode = AIError.GetLastError();

        if (errorCode == AIVehicle.ERR_VEHICLE_TOO_MANY)
        {
            Log.Warning("Unable to create vehicles for route; we've reached max road vehicles.", Log.LVL_INFO)
            this.at_max_RV_count = true;
            return -1;
        }
        else
        {
            Log.Error("Unable to create vehicles for route: unhandled error: " + AIError.GetLastErrorString(), Log.LVL_INFO);
            return -1;
        }
    }

    //give this bus orders
    //Log.Info("The capacity of this bus is " + AIVehicle.GetCapacity(buses[0], this.passenger_cargo_id), Log.LVL_DEBUG);

    AIOrder.AppendOrder(buses[0], startStationTile, AIOrder.AIOF_NONE);
    AIOrder.AppendOrder(buses[0], endStationTile, AIOrder.AIOF_NONE);

    for (local x = 1; x < 3; x++) //purchase subsequent buses
    {
        buses.push(AIVehicle.CloneVehicle(useDepot, buses[0], true));
    }


    Log.Info("Vehicles purchased. Starting them.", Log.LVL_SUB_DECISIONS);

    for (local y = 0; y < 3; y++)
    {
        AIVehicle.StartStopVehicle(buses[y]);
        this.Sleep(150);
    }

    //make sure we don't use these towns again
    this.towns_used.AddItem(townStart, AITown.GetLocation(townStart));
    this.towns_used.AddItem(townEnd, AITown.GetLocation(townEnd));

    this.last_route_tick = this.GetTick(); //record time of route creation

    //record the depots for these stations
    if (useDepot == endDepotTile) startDepotTile = endDepotTile;
    this.station_depot_pairs.AddItem(startStationTile, startDepotTile);
    this.station_depot_pairs.AddItem(endStationTile, endDepotTile);

    //record this set of stations as a route (need to store it both ways for list functionality)
    this.station_pairs.AddItem(AIStation.GetStationID(startStationTile), AIStation.GetStationID(endStationTile));
    this.station_pairs.AddItem(AIStation.GetStationID(endStationTile), AIStation.GetStationID(startStationTile));

    Log.Info("Route complete!", Log.LVL_INFO);

    return 1; //stations, depots, and vehicles built, and buses have started.
}

function TeshiNet::GetPassengerTownPair()
{
    local pair = null;
    local first = -1;
    local second = -1;
    local firstloc = null;
    local townList= null;
    local timeout = 0

    local maxDist = null;
    local curYear = AIDate.GetYear(AIDate.GetCurrentDate());

    //Restrict route distance by year, as a rough approximation of vehicle speed
    //This should prevent us from building routes that are too long to be profitable with slow buses

    if (curYear > 1987)
    {
        maxDist = 115;
    }
    else
    {
        if (curYear > 1965)
        {
            maxDist = 80;
        }
        else
        {
            maxDist = 50;
        }
    }

    do
    {

        townList = AITownList(); //populate a list of towns

        townList.RemoveList(this.towns_used); //remove the ones we already serve

        townList.Valuate(AITown.GetPopulation); //only towns 500 pop and above
        townList.KeepAboveValue(499);

        Log.Info("There are " + townList.Count() + " towns in the list for first town.", Log.LVL_DEBUG);

        townList.Valuate(AIBase.RandItem); //now, let's randomize the list
        townList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING);

        first = townList.Begin();  //we'll take the first one at random.
        firstloc = AITown.GetLocation(first);

        townList.RemoveTop(1); // so we'll take that one off the list
        Log.Info("Found a first town, " + AITown.GetName(first) + ", looking for a second between 10-" + maxDist + " squares away.", Log.LVL_SUB_DECISIONS);

        townList = AITownList(); //repopulate the list
        townList.RemoveList(this.towns_used);

        townList.Valuate(AITown.GetPopulation);
        townList.KeepAboveValue(499); //only towns 500 people and up

        townList.Valuate(this.TownDistance, firstloc);
        townList.KeepBetweenValue(10, maxDist);

        if (townList.IsEmpty())
        {
            Log.Info("No suitable matches for " + AITown.GetName(first) + ". Picking a new start town.", Log.LVL_SUB_DECISIONS);
            second = -1;
            timeout++;
            continue;
        }

        townList.Valuate(AIBase.RandItem);
        townList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING);

        second = townList.Begin();
        Log.Info("Found a second town, " + AITown.GetName(second), Log.LVL_SUB_DECISIONS);

    } while (second == -1 && timeout < 10)
    if (second == -1)
    {
        Log.Error("Unable to find a suitable town pair.", Log.LVL_INFO);
        return -1;
    }

    pair = [first, second]
    return pair;
}

function TeshiNet::ManageBusyBusStations()
{
    local stationList = AIStationList(AIStation.STATION_BUS_STOP); //make a list of stations

    stationList.Valuate(AIStation.GetCargoWaiting, this.passenger_cargo_id); //value them by passengers waiting
    stationList.KeepAboveValue(200); //let's increase if they're above 200
    stationList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_DESCENDING); //starting with the busiest station, since we might run out of cash or vehicles

    if (stationList.IsEmpty()) // if the list is empty, then all stations are below 200 waiting cargo, no need to increase capacity
    {
        Log.Info("No bus stations with excessive waiting cargo.", Log.LVL_SUB_DECISIONS);
        return -1;
    }

    for (local curStation = stationList.Begin(); stationList.HasNext(); curStation = stationList.Next())
    {
        local vehList = AIVehicleList_Station(curStation); //make a list of vehicles at this station, so we can count them

        local numveh = vehList.Count();

        local staTiles = AITileList_StationType(curStation, AIStation.STATION_BUS_STOP);

        local staSize = staTiles.Count();

        if ((numveh / 15.0) > staSize) //desired ratio is 1 station tile for every 15 vehicles or fraction thereof.
        {
            Log.Info("More than 15 vehicles per area at " + AIStation.GetName(curStation) + ". Building a new loading area at each end.", Log.LVL_INFO);
            local return1 = Road.GrowStation(curStation, AIStation.STATION_BUS_STOP);
            if (SuperLib.Result.IsSuccess(return1))
            {
                Road.GrowStation(this.station_pairs.GetValue(curStation), AIStation.STATION_BUS_STOP); //the other end of this route
            }
            else
            {
                Log.Info("Unable to grow the station. Will try again later.", Log.LVL_INFO);
            }
        }

        CloneVehicleByStation(curStation);
    }
}

function TeshiNet::CloneVehicleByStation(station)
{
    local vehList = AIVehicleList_Station(station); //make a list of vehicles at this station, so we can find one to clone

    vehList.Valuate(AIVehicle.GetProfitLastYear); //find the most profitable vehicle to clone
    vehList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_DESCENDING);

    local depot = this.station_depot_pairs.GetValue(AIStation.GetLocation(station));

    local toClone = vehList.Begin();
    local costToClone = AIEngine.GetPrice(AIVehicle.GetEngineType(toClone));

    if (AICompany.GetBankBalance(AICompany.COMPANY_SELF) > (2 * costToClone))
    {
        Log.Info("Adding one vehicle to serve " + AIStation.GetName(station), Log.LVL_SUB_DECISIONS);
        local newveh = AIVehicle.CloneVehicle(depot, toClone, true);

        if (!AIVehicle.IsValidVehicle(newveh))
        {
            local errorCode = AIError.GetLastError();

            if (errorCode == AIVehicle.ERR_VEHICLE_TOO_MANY)
            {
                Log.Warning("Unable to create vehicle for route; we've reached max road vehicles.", Log.LVL_INFO)
                this.at_max_RV_count = true;
                return -1;
            }
            else
            {
                Log.Error("Unable to create vehicles for route: unhandled error: " + AIError.GetLastErrorString(), Log.LVL_INFO);
                return -1;
            }
        }

        AIVehicle.StartStopVehicle(newveh);

    }
    else
    {
        Log.Warning("Need vehicle for " + AIStation.GetName(station) + " but there's not enough money.", Log.LVL_INFO)
    }
}

function TeshiNet::TownDistance(townID, location)
{
    return AIMap.DistanceManhattan(AITown.GetLocation(townID), location);
}

function TeshiNet::IndustryDistance(industryID, location)
{
    return AIMap.DistanceManhattan(AIIndustry.GetLocation(industryID), location);
}

function TeshiNet::RemoveDeadRoadStations()
{
    Log.Info("Removing unused bus stations.", Log.LVL_SUB_DECISIONS);
    local stationList = AIStationList(AIStation.STATION_BUS_STOP);

    for (local curSta = stationList.Begin(); stationList.HasNext(); curSta = stationList.Next())
    {
        local stationVehs = AIVehicleList_Station(curSta);

        if (stationVehs.IsEmpty())
        {
            Log.Info("Station " + AIStation.GetName(curSta) + " is not in use. Removing.", Log.LVL_SUB_DECISIONS);
            Station.DemolishStation(curSta);
            AIRoad.RemoveRoadDepot(this.station_depot_pairs.GetValue(curSta));
            this.station_depot_pairs.RemoveItem(curSta);
            this.towns_used.RemoveItem(AIStation.GetNearestTown(curSta));
            this.station_pairs.RemoveItem(curSta);
        }
        this.Sleep(1);
    }

    Log.Info("Removing unused truck stations.", Log.LVL_SUB_DECISIONS);
    local stationList = AIStationList(AIStation.STATION_TRUCK_STOP);

    for (local curSta = stationList.Begin(); stationList.HasNext(); curSta = stationList.Next())
    {
        local stationVehs = AIVehicleList_Station(curSta);

        if (stationVehs.IsEmpty())
        {
            Log.Info("Station " + AIStation.GetName(curSta) + " is not in use. Removing.", Log.LVL_SUB_DECISIONS);
            Station.DemolishStation(curSta);
            AIRoad.RemoveRoadDepot(this.station_depot_pairs.GetValue(curSta));
            this.station_depot_pairs.RemoveItem(curSta);
            this.industries_by_station.RemoveItem(curSta);
            this.stations_by_industry.RemoveValue(curSta);
        }
        this.Sleep(1);
    }
}

function TeshiNet::RemoveLeastProfRoadRoute()
{
    Log.Info("Searching for least profitable road route for removal.", Log.LVL_INFO);

    //we do not need to check against number of routes anymore as we are only calling this function when we are at max RV count

    local routeProfits = AIList(); //create a list to store the average profit of each route

    local staList = AIStationList(AIStation.STATION_BUS_STOP);

    for (local route = staList.Begin(); staList.HasNext(); route = staList.Next()) //iterate through our bus stations
    {
        local vehicles = AIVehicleList_Station(route);

        if (vehicles.IsEmpty()) continue;

        vehicles.Valuate(AIVehicle.GetAge); //how old are they?
        vehicles.KeepAboveValue(365 * 2); //we only want to calculate on vehicles that have had two full years to run. this ensures last year's profit is a full year.

        if (vehicles.IsEmpty()) continue; //young route? give it a chance.

        vehicles.Valuate(AIVehicle.GetProfitLastYear);

        local revenuetotal = 0;

        for (local veh = vehicles.Begin(); vehicles.HasNext(); veh = vehicles.Next())
        {
            revenuetotal += vehicles.GetValue(veh);
        }

        local meanprofit = revenuetotal / vehicles.Count(); //calculate the mean profit (total revenue divided by total vehicle count)

        routeProfits.AddItem(route, meanprofit); //add this route with profit total to the list.

    }

    staList = AIStationList(AIStation.STATION_TRUCK_STOP);

    for (local route = staList.Begin(); staList.HasNext(); route = staList.Next()) //iterate through our truck stations
    {
        local vehicles = AIVehicleList_Station(route);

        if (vehicles.IsEmpty()) continue;

        vehicles.Valuate(AIVehicle.GetAge); //how old are they?
        vehicles.KeepAboveValue(365 * 2); //we only want to calculate on vehicles that have had two full years to run. this ensures last year's profit is a full year.

        if (vehicles.IsEmpty()) continue; //young route? give it a chance.

        vehicles.Valuate(AIVehicle.GetProfitLastYear);

        local revenuetotal = 0;

        for (local veh = vehicles.Begin(); vehicles.HasNext(); veh = vehicles.Next())
        {
            revenuetotal += vehicles.GetValue(veh);
        }

        local meanprofit = revenuetotal / vehicles.Count(); //calculate the mean profit (total revenue divided by total vehicle count)

        routeProfits.AddItem(route, meanprofit); //add this route with profit total to the list.
    }

    routeProfits.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING); //the route at the top is our least profitable by vehicle

    if (routeProfits.IsEmpty())
    {
        Log.Info("No routes are eligible for removal at this time.", Log.LVL_SUB_DECISIONS);
        return -1;
    }

    local deadRoute = routeProfits.Begin(); //this is the station index of the first station on the least profitable route.

    if (routeProfits.GetValue(deadRoute) >= 10000 && !this.at_max_RV_count) //min profit to score, $20,000 or 10,000 pounds
    {
        Log.Info("Our least profitable road route is earning over 10,000 pounds per vehicle. Aborting removal.", Log.LVL_INFO);
        return -1;
    }

    local deadRouteStart = deadRoute;
    local deadRouteEnd = this.station_pairs.GetValue(deadRouteStart); //the "value" of the first station is the index of the second station in the route

    Log.Info("The route from " + AIStation.GetName(deadRouteStart) + " to " + AIStation.GetName(deadRouteEnd) + " is our least profitable route per vehicle. Killing this route.", Log.LVL_INFO);
    Log.Info("The average profit per vehicle last year was " + routeProfits.GetValue(deadRoute) + " (pounds) on this route.", Log.LVL_SUB_DECISIONS);

    RemoveRoadRoute(deadRouteStart, deadRouteEnd);
}

function TeshiNet::RemoveRoadRoute(start_station, end_station)
{
    local deadRoute = start_station;
    local deadRouteStart = start_station;
    local deadRouteEnd = end_station;
    local deadVehicles = AIVehicleList_Station(deadRoute);

    //is this a passenger or cargo route?
    local passRoute = false;
    local routeCargo = AIEngine.GetCargoType(deadVehicles.Begin());
    if (routeCargo == this.passenger_cargo_id) passRoute = true;

    Log.Info("Sending vehicles to depot and selling them.", Log.LVL_SUB_DECISIONS);

    local money = AIAccounting();

    local depotLoc = this.station_depot_pairs.GetValue(AIStation.GetLocation(deadRoute));

    for (local curVeh = deadVehicles.Begin(); deadVehicles.HasNext(); curVeh = deadVehicles.Next())
    {
        AIOrder.UnshareOrders(curVeh); //unshare orders

        do //delete existing orders
        {
            AIOrder.RemoveOrder(curVeh, 0);
        } while (AIOrder.GetOrderCount(curVeh) > 0)

        AIOrder.AppendOrder(curVeh, depotLoc, AIOrder.AIOF_STOP_IN_DEPOT); //send to depot
    }

    this.Sleep(100); //give them time to arrive
    local timeout = 0;

    do
    {
        local sold = 0;

        for (local curVeh = deadVehicles.Begin(); deadVehicles.HasNext(); curVeh = deadVehicles.Next())
        {
            if (AIVehicle.IsStoppedInDepot(curVeh))
            {
                sold = AIVehicle.SellVehicle(curVeh);
                if (sold)
                {
                    deadVehicles.RemoveItem(curVeh);
                }
            }

        }

        this.Sleep(100); //give the rest some more time
        timeout++;

    } while (!deadVehicles.IsEmpty() && timeout < 45)

    if (!deadVehicles.IsEmpty())
    { //once more, with feeling!
        Log.Info("Seems that not all of the vehicles made it to the depot. We'll try one more time.", Log.LVL_SUB_DECISIONS);

        this.Sleep(25); //give them some time to get there
        local timeout = 0;

        do
        {
            deadVehicles.Valuate(AIVehicle.IsStoppedInDepot);
            deadVehicles.KeepValue(1);

            for (local curVeh = deadVehicles.Begin(); deadVehicles.HasNext(); curVeh = deadVehicles.Next())
            {
                AIVehicle.SellVehicle(curVeh);
            }

            deadVehicles = AIVehicleList_Station(deadRoute);

            this.Sleep(100); //give the rest some more time
            timeout++;

        } while (!deadVehicles.IsEmpty() && timeout < 45)
    }

    Log.Info("Vehicles sold; removing stations.", Log.LVL_SUB_DECISIONS);

    if (passRoute) //clean up our indexes
    {
        this.towns_used.RemoveItem(AITile.GetClosestTown(AIStation.GetLocation(deadRouteStart)));
        this.towns_used.RemoveItem(AITile.GetClosestTown(AIStation.GetLocation(deadRouteEnd)));
    }
    else
    {
        local indStart = this.industries_by_station.GetValue(deadRouteStart);
        local indEnd = this.industries_by_station.GetValue(deadRouteEnd);
        this.industries_by_station.RemoveItem(deadRouteStart);
        this.industries_by_station.RemoveItem(deadRouteEnd);
        this.stations_by_industry.RemoveItem(indStart);
        this.stations_by_industry.RemoveItem(indEnd);
    }

    //Use SuperLib station removal routines
    Station.DemolishStation(deadRouteStart);
    Station.DemolishStation(deadRouteEnd);

    AIRoad.RemoveRoadDepot(depotLoc); //remove the start depot, we already know its location

    depotLoc = this.station_depot_pairs.GetValue(AIStation.GetLocation(deadRouteEnd)); //find the location of the end depot

    AIRoad.RemoveRoadDepot(depotLoc); //remove it

    this.station_pairs.RemoveItem(deadRouteStart); //clean up our indexes
    this.station_depot_pairs.RemoveItem(deadRouteStart);
    this.station_pairs.RemoveItem(deadRouteEnd);
    this.station_depot_pairs.RemoveItem(deadRouteEnd);

    Log.Info("Cost of route removal was " + money.GetCosts() + " pounds.", Log.LVL_SUB_DECISIONS);
    return 1;
}

function TeshiNet::RemoveRoadStation(curSta)
{
    local stationLoc = AIStation.GetLocation(curSta);

    local searchArea = AITileList_StationType(curSta, AIStation.STATION_BUS_STOP);

    if (searchArea.IsEmpty())
    {
        searchArea = AITileList_StationType(curSta, AIStation.STATION_TRUCK_STOP);
    }

    for (local tile = searchArea.Begin(); searchArea.HasNext(); tile = searchArea.Next())
    {
        AIRoad.RemoveRoadStation(tile);
    }

    local depotLoc = this.station_depot_pairs.GetValue(stationLoc);

    AIRoad.RemoveRoadDepot(depotLoc);

    this.station_pairs.RemoveItem(curSta);
    this.station_depot_pairs.RemoveItem(curSta);

}

function TeshiNet::GetIndustryPair()
{

    local pair = null;
    local cargo = null;
    local source = null;
    local dest = null;
    local cargoList = AICargoList();
    local maxDist = null;

    local curYear = AIDate.GetYear(AIDate.GetCurrentDate());

    //Restrict distance between route pairs by year and bank balance,
    //to prevent from losing money early game when vehicles are slow

    if (curYear < 1977)
    {
        maxDist = 50;
    }
    else
    {
        if (AICompany.GetBankBalance(AICompany.COMPANY_SELF) > 1000000)
        {
            maxDist = 125;
        }
        else
        {
            maxDist = 100;
        }
    }

    cargoList.Valuate(AIBase.RandRangeItem, 32767);
    cargoList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_DESCENDING);

    cargo = cargoList.Begin();

    if (cargo == this.passenger_cargo_id) cargo = cargoList.Next();

    if (cargo == this.mail_cargo_id) cargo = cargoList.Next();

    if (AICargo.GetTownEffect(cargo) == AICargo.TE_GOODS) cargo = cargoList.Next();

    Log.Info("We're going to look for " + AICargo.GetCargoLabel(cargo) + " industries.", Log.LVL_SUB_DECISIONS);

    local sourceList = AIIndustryList_CargoProducing(cargo);

    sourceList.RemoveList(this.industries_used); //remove the industries we already use

    sourceList.Valuate(AIIndustry.GetLastMonthProduction, cargo);  //valuate by total production
    sourceList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_DESCENDING);

    sourceList.KeepTop(sourceList.Count() / 2); //keep the top half

    sourceList.Valuate(AIBase.RandRangeItem, 32767);
    sourceList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING);

    for (source = sourceList.Begin(); sourceList.HasNext(); source = sourceList.Next())
    {
        source = sourceList.Next();

        if (AIIndustry.GetLastMonthProduction(source, cargo) == 0) continue;
        if (AIIndustry.IsBuiltOnWater(source)) continue;

        local destList = AIIndustryList_CargoAccepting(cargo);
        destList.RemoveList(this.industries_used);

        destList.Valuate(IndustryDistance, AIIndustry.GetLocation(source));
        destList.KeepBetweenValue(10, maxDist);

        if (destList.IsEmpty()) continue;

        destList.Valuate(AIBase.RandRangeItem, 32767);
        destList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING);

        dest = destList.Begin();
        break;
    }

    if (dest == null)
    {
        Log.Info("Unable to find a matching pair for this type of cargo.  Will skip.", Log.LVL_SUB_DECISIONS);
        this.last_cargo = cargo;
        return -1;
    }

    pair = [source, dest, cargo];

    Log.Info("Industry pair found: " + AIIndustry.GetName(source) + " to " + AIIndustry.GetName(dest), Log.LVL_SUB_DECISIONS);

    return pair;
}

function TeshiNet::SellUnusedVehicles() //find vehicles without orders, send them to the depot, and sell them
{
    Log.Info("Selling vehicles with invalid or no orders.", Log.LVL_INFO);
    local longList = AIList();
    local deadVehicles = AIVehicleList();

    deadVehicles.Valuate(AIOrder.GetOrderCount);
    deadVehicles.KeepBelowValue(2); //keep only vehicles with 1 or 0 orders.

    Log.Info("Found " + deadVehicles.Count() + " vehicles with less than two orders each.", Log.LVL_SUB_DECISIONS);

    longList.AddList(deadVehicles); //add the 0-order vehicles to the master list

    deadVehicles = AIVehicleList(); //repopulate
    deadVehicles.RemoveList(longList); //don't re-check the ones we've already found

    local invalidCount = 0;

    for (local curVeh = deadVehicles.Begin(); deadVehicles.HasNext(); curVeh = deadVehicles.Next())
    {
        local count = AIOrder.GetOrderCount(curVeh);
        for (local i = 0; i < count; i++)
        {
            local dest = AIOrder.GetOrderDestination(curVeh, i);

            if (!AIMap.IsValidTile(dest)) //is the order valid? if not, add the vehicle to the removal list
            {
                longList.AddItem(curVeh, 1);
                invalidCount++;
                break;
            }
        }
    }

    Log.Info("Found " + invalidCount + " vehicles with invalid orders.", Log.LVL_SUB_DECISIONS);

    //RV only!
    longList.Valuate(AIVehicle.GetVehicleType);
    longList.KeepValue(AIVehicle.VT_ROAD);

    if (longList.Count() == 0)
    {
        return 1;
    }

    local sent = 0;
    local sentTotal = 0;

    for (local curVeh = longList.Begin(); longList.HasNext(); curVeh = longList.Next())
    {
        sent = AIVehicle.SendVehicleToDepot(curVeh);
        if (!sent)
        {
            longList.RemoveItem(curVeh);
        }
        else
        {
            sentTotal++;
        }
    }

    Log.Info("Was able to send " + sentTotal + " of these vehicles to a depot.", Log.LVL_SUB_DECISIONS);

    if (sentTotal == 0) //if we couldn't send any to the depot, we probably need to build a depot.
    {
        ForceSellUnusedVeh();
        return;
    }

    this.Sleep(100); //give them time to arrive
    local timeout = 0;

    local money = AIAccounting();

    do
    {
        local sold = 0;

        for (local curVeh = longList.Begin(); longList.HasNext(); curVeh = longList.Next())
        {
            if (AIVehicle.IsStoppedInDepot(curVeh))
            {
                sold = AIVehicle.SellVehicle(curVeh);
                if (sold)
                {
                    longList.RemoveItem(curVeh);
                }
            }
        }

        this.Sleep(100); //give the rest some more time
        timeout++;

    } while (!longList.IsEmpty() && timeout < 45)

    Log.Info("Recovered " + money.GetCosts() + " pounds by selling them.", Log.LVL_SUB_DECISIONS);
}

function TeshiNet::ForceSellUnusedVeh() //when the main function can't handle it, build a depot and try again
{
    Log.Info("Trying to build a depot to sell these.", Log.LVL_SUB_DECISIONS);
    local longList = AIList();
    local deadVehicles = AIVehicleList();

    deadVehicles.Valuate(AIOrder.GetOrderCount);
    deadVehicles.KeepBelowValue(2); //keep only vehicles with 1 or 0 orders.

    longList.AddList(deadVehicles); //add the 0-order vehicles to the master list

    deadVehicles = AIVehicleList(); //repopulate
    deadVehicles.RemoveList(longList); //don't re-check the ones we've already found

    local invalidCount = 0;

    for (local curVeh = deadVehicles.Begin(); deadVehicles.HasNext(); curVeh = deadVehicles.Next())
    {
        local count = AIOrder.GetOrderCount(curVeh);
        for (local i = 0; i < count; i++)
        {
            local dest = AIOrder.GetOrderDestination(curVeh, i);

            if (!AIMap.IsValidTile(dest)) //is the order valid? if not, add the vehicle to the removal list
            {
                longList.AddItem(curVeh, 1);
                invalidCount++;
                break;
            }
        }
    }

    //RV only!
    longList.Valuate(AIVehicle.GetVehicleType);
    longList.KeepValue(AIVehicle.VT_ROAD);

    if (longList.Count() == 0)
    {
        return 1;
    }

    //build a depot
    local depotLoc = Road.BuildDepotNextToRoad(AIVehicle.GetLocation(longList.Begin()), 1, 500);

    local sent = 0;
    local sentTotal = 0;

    for (local curVeh = longList.Begin(); longList.HasNext(); curVeh = longList.Next())
    {
        sent = AIVehicle.SendVehicleToDepot(curVeh);
        if (!sent)
        {
            longList.RemoveItem(curVeh);
        }
        else
        {
            sentTotal++;
        }
    }

    Log.Info("After building a depot, was able to send " + sentTotal + " of them to a depot.", Log.LVL_SUB_DECISIONS);

    if (sentTotal == 0) //if we couldn't send any to the depot, we will remove it and try again another time.
    {
        AIRoad.RemoveRoadDepot(depotLoc);
        return;
    }

    this.Sleep(100); //give them time to arrive
    local timeout = 0;

    local money = AIAccounting();

    do
    {
        local sold = 0;

        for (local curVeh = longList.Begin(); longList.HasNext(); curVeh = longList.Next())
        {
            if (AIVehicle.IsStoppedInDepot(curVeh))
            {
                sold = AIVehicle.SellVehicle(curVeh);
                if (sold)
                {
                    longList.RemoveItem(curVeh);
                }
            }
        }

        this.Sleep(100); //give the rest some more time
        timeout++;

    } while (!longList.IsEmpty() && timeout < 45)

    AIRoad.RemoveRoadDepot(depotLoc);

    Log.Info("Recovered " + money.GetCosts() + " pounds by selling them.", Log.LVL_SUB_DECISIONS);
}

function TeshiNet::RemoveUnprofitableRoadRoute()
{
    Log.Info("Searching for unprofitable road routes for removal.", Log.LVL_INFO);

    local routeProfits = AIList(); //create a list to store the average profit of each route

    local staList = AIStationList(AIStation.STATION_BUS_STOP);

    for (local route = staList.Begin(); staList.HasNext(); route = staList.Next()) //iterate through our bus stations
    {
        local vehicles = AIVehicleList_Station(route);

        if (vehicles.IsEmpty()) continue;

        vehicles.Valuate(AIVehicle.GetAge); //how old are they?
        vehicles.KeepAboveValue(365 * 2); //we only want to calculate on vehicles that have had two full years to run. this ensures last year's profit is a full year.

        if (vehicles.IsEmpty()) continue; //young route? give it a chance.

        vehicles.Valuate(AIVehicle.GetProfitLastYear);

        local revenuetotal = 0;

        for (local veh = vehicles.Begin(); vehicles.HasNext(); veh = vehicles.Next())
        {
            revenuetotal += vehicles.GetValue(veh);
        }

        local meanprofit = revenuetotal / vehicles.Count(); //calculate the mean profit (total revenue divided by total vehicle count)

        routeProfits.AddItem(route, meanprofit); //add this route with profit total to the list.

    }

    staList = AIStationList(AIStation.STATION_TRUCK_STOP);

    for (local route = staList.Begin(); staList.HasNext(); route = staList.Next()) //iterate through our truck stations
    {
        local vehicles = AIVehicleList_Station(route);

        if (vehicles.IsEmpty()) continue;

        vehicles.Valuate(AIVehicle.GetAge); //how old are they?
        vehicles.KeepAboveValue(365 * 2); //we only want to calculate on vehicles that have had two full years to run. this ensures last year's profit is a full year.

        if (vehicles.IsEmpty()) continue; //young route? give it a chance.

        vehicles.Valuate(AIVehicle.GetProfitLastYear);

        local revenuetotal = 0;

        for (local veh = vehicles.Begin(); vehicles.HasNext(); veh = vehicles.Next())
        {
            revenuetotal += vehicles.GetValue(veh);
        }

        local meanprofit = revenuetotal / vehicles.Count(); //calculate the mean profit (total revenue divided by total vehicle count)

        routeProfits.AddItem(route, meanprofit); //add this route with profit total to the list.
    }

    routeProfits.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING); //the route at the top is our least profitable by vehicle
    routeProfits.KeepBelowValue(1); //only negative or 0 amounts (negative profits)

    if (routeProfits.IsEmpty())
    {
        Log.Info("No routes are entirely unprofitable at this time.", Log.LVL_SUB_DECISIONS);
        return -1;
    }

    //iterate through and remove all unprofitable routes
    for (local deadRoute = routeProfits.Begin(); routeProfits.HasNext(); deadRoute = routeProfits.Next())
    {
        local deadRouteStart = deadRoute;
        local deadRouteEnd = this.station_pairs.GetValue(deadRouteStart); //the "value" of the first station is the index of the second station in the route

        Log.Info("The route from " + AIStation.GetName(deadRouteStart) + " to " + AIStation.GetName(deadRouteEnd) + " is unprofitable. Killing this route.", Log.LVL_INFO);
        Log.Info("The average profit per vehicle last year was " + routeProfits.GetValue(deadRoute) + " pounds on this route.", Log.LVL_SUB_DECISIONS);

        RemoveRoadRoute(deadRouteStart, deadRouteEnd);
        routeProfits.RemoveItem(deadRouteEnd);
    }
}

function TeshiNet::IsRouteProfitable(startStation)
{
    local vehicles = AIVehicleList_Station(startStation);

    if (vehicles.IsEmpty()) return true;

    vehicles.Valuate(AIVehicle.GetAge); //how old are they?
    vehicles.KeepAboveValue(365 * 2); //we only want to calculate on vehicles that have had two full years to run. this ensures last year's profit is a full year.

    if (vehicles.IsEmpty()) return true; //young route? give it a chance.

    vehicles.Valuate(AIVehicle.GetProfitLastYear);

    local revenuetotal = 0;

    for (local veh = vehicles.Begin(); vehicles.HasNext(); veh = vehicles.Next())
    {
        revenuetotal += vehicles.GetValue(veh);
    }

    local meanprofit = revenuetotal / vehicles.Count(); //calculate the mean profit (total revenue divided by total vehicle count)

    if (meanprofit >= 0)
    {
        return true;
    }
    else
    {
        return false;
    }
}

function TeshiNet::UpgradeRoadVehicles()
{
    //make a list of all engine types currently in use
    //evaluate each to see if an upgrade is available, replace if so

    Log.Info("Searching for road vehicle upgrades.", Log.LVL_INFO);

    local enginesInUse = [];
    local vehicles = AIVehicleList();
    local engine = 0;

    vehicles.Valuate(AIVehicle.GetVehicleType);
    vehicles.KeepValue(AIVehicle.VT_ROAD);

    vehicles.Valuate(AIVehicle.GetEngineType);
    vehicles.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING);

    for (local x = vehicles.Begin(); vehicles.HasNext(); x = vehicles.Next())
    {
        enginesInUse.push(vehicles.GetValue(x));
        vehicles.RemoveValue(vehicles.GetValue(x));
    }

    foreach (engine in enginesInUse)
    {
        local cargo = AIEngine.GetCargoType(engine);
        local possReplace = AIEngineList(AIVehicle.VT_ROAD);

        possReplace.Valuate(AIEngine.GetRoadType); //regular RV's only, no trams
        possReplace.KeepValue(AIRoad.ROADTYPE_ROAD);

        possReplace.Valuate(AIEngine.GetCargoType); //only the type of cargo we want
        possReplace.KeepValue(cargo);

        if (possReplace.IsEmpty()) //no vehicles for this cargo?
        {
            possReplace = AIEngineList(AIVehicle.VT_ROAD); //repopulate the list

            possReplace.Valuate(AIEngine.GetRoadType); //regular RV's only, no trams
            possReplace.KeepValue(AIRoad.ROADTYPE_ROAD);

            possReplace.Valuate(AIEngine.CanRefitCargo, cargo); //look for vehicles that can be refit instead
            possReplace.KeepValue(1);
        }

        if (possReplace.IsEmpty()) //still empty?
        {
            continue;
        }

        possReplace.Valuate(AIEngine.IsArticulated); //no articulated vehicles
        possReplace.KeepValue(0);

        possReplace.Valuate(AIEngine.GetMaxSpeed);
        possReplace.KeepTop(1);

        local candidate = possReplace.Begin();

        if (possReplace.GetValue(candidate) > AIEngine.GetMaxSpeed(engine))
        {
            //the fastest vehicle for this cargo is faster than one we are using. let's replace them
            AIGroup.SetAutoReplace(AIGroup.GROUP_ALL, engine, candidate);
            Log.Info("Replacing " + AIEngine.GetName(engine) + " with " + AIEngine.GetName(candidate), Log.LVL_INFO);
        }
    }

    Log.Info("Road vehicle upgrade search complete.", Log.LVL_INFO);
}

function TeshiNet::GradeSeparateCrossing(tile_index)
{
    local prevRoad = null;
    local candidate = null;
    local dirList = Direction.GetMainDirsInRandomOrder();

    for (local dir = dirList.Begin(); dirList.HasNext(); dir = dirList.Next()) //find the neighbor road to pass to the bridge function
    {
        candidate = Direction.GetAdjacentTileInDirection(tile_index, dir);

        if (AIRoad.IsRoadTile(candidate))
        {
            prevRoad = candidate;
            break;
        }
    }

    local result = Road.ConvertRailCrossingToBridge(tile_index, prevRoad);

    if (result.succeeded == true)
    {
        return 1;
    }
    else
    {
        return 0;
    }
}

function TeshiNet::EventHandler()
{
    local event = this.event_queue.Pop();
    switch (event.GetEventType())
    {
        case AIEvent.AI_ET_INDUSTRY_CLOSE:
            local closeEvent = AIEventIndustryClose.Convert(event);
            local closedInd = closeEvent.GetIndustryID();

            //although we checked if we serve the industry when we queued the closure event, it's remotely possible
            //that we might have already removed the affected route, so let's check again before removing

            if (this.stations_by_industry.HasItem(closedInd))
            {
                local station = this.stations_by_industry.GetValue(closedInd);
                Log.Info("Station " + AIStation.GetName(station) + " serves an industry which is closing. Removing route.", Log.LVL_INFO);
                RemoveRoadRoute(station, this.station_pairs.GetValue(station));
            }
            else
            {
                Log.Info("Queued industry closing message does not affect us.", Log.LVL_DEBUG);
            }
            break;

        case AIEvent.AI_ET_VEHICLE_UNPROFITABLE:
            local vehicleEvent = AIEventVehicleUnprofitable.Convert(event);
            local veh = vehicleEvent.GetVehicleID();

            if (AIVehicle.GetVehicleType(veh) != AIVehicle.VT_ROAD) //we already handle planes elsewhere
            {
                Log.Info("An unprofitable vehicle message was queued, but it is not a road vehicle.", Log.LVL_INFO);
                break;
            }

            local station = AIStation.GetStationID(AIOrder.GetOrderDestination(veh, 0));
            local dest = this.station_pairs.GetValue(station);
            local depotLoc = this.station_depot_pairs.GetValue(AIStation.GetLocation(station));

            if (!AIVehicle.IsValidVehicle(veh))
            {
                Log.Info("We queued an unprofitable vehicle message, but it has already been sold or destroyed.", Log.LVL_INFO);
                break;
            }

            Log.Info(AIVehicle.GetName(veh) + " serving " + AIStation.GetName(station) + " did not turn a profit last year.", Log.LVL_INFO);

            if (!AIVehicle.SendVehicleToDepot(veh)) //send to depot
            {
                AIOrder.UnshareOrders(veh); //if it didn't get the message, unshare/remove orders and add a manual depot order

                do //delete existing orders
                {
                    AIOrder.RemoveOrder(veh, 0);
                } while (AIOrder.GetOrderCount(veh) > 0)

                local order = AIOrder.AppendOrder(veh, depotLoc, AIOrder.AIOF_STOP_IN_DEPOT); //send to depot

                if (!order)
                {
                    Log.Error("Unable to send vehicle to depot. It will be picked up by next no-orders check.", Log.LVL_SUB_DECISIONS);
                    break;
                }
            }

            Log.Info("Sent " + AIVehicle.GetName(veh) + " to depot.", Log.LVL_SUB_DECISIONS);

           /* this.Sleep(150); //give it a little time

            local timeout = 0;

            do //wait for it to arrive, and sell it
            {
                if (AIVehicle.IsStoppedInDepot(veh))
                {
                    AIVehicle.SellVehicle(veh);
                }
                else
                {
                    this.Sleep(150);
                }
                timeout++
            } while (AIVehicle.IsValidVehicle(veh) && timeout < 50) */

            break;

        case AIEvent.AI_ET_VEHICLE_CRASHED:
            local crashEvent = AIEventVehicleCrashed.Convert(event);
            local vehicle = crashEvent.GetVehicleID();

            if (!AIVehicle.IsValidVehicle(vehicle))
            {
                Log.Info("Vehicle crashed, but the wreck cleared before we handled the event. Unable to replace vehicle.", Log.LVL_INFO);
                break;
            }

            local location = crashEvent.GetCrashSite();
            local reason = crashEvent.GetCrashReason();
            local station = AIStation.GetStationID(AIOrder.GetOrderDestination(vehicle, 0));

            Log.Info("Vehicle crashed. Cloning replacement vehicle.", Log.LVL_INFO);
            CloneVehicleByStation(station);

            if (reason == AIEventVehicleCrashed.CRASH_RV_LEVEL_CROSSING) //was this a road vehicle run over by a train?
            {
                Log.Info("Crash was due to a level crossing. Attempting to grade-separate crossing.", Log.LVL_INFO);
                local result = GradeSeparateCrossing(location);

                if (result == 1)
                {
                    Log.Info("Grade separation successful.", Log.LVL_INFO);
                }
                else
                {
                    Log.Info("Grade separation unsuccessful.", Log.LVL_INFO);
                }
            }

            break;

        case AIEvent.AI_ET_VEHICLE_WAITING_IN_DEPOT:
            local waitingEvent = AIEventVehicleWaitingInDepot.Convert(event);
            local vehicle = waitingEvent.GetVehicleID();

            if (!AIVehicle.IsValidVehicle(vehicle))
            {
                Log.Info("We queued a vehicle-in-depot notification, but the vehicle is no longer valid.", Log.LVL_DEBUG);
                break;
            }

            Log.Info("Selling " + AIVehicle.GetName(vehicle), Log.LVL_INFO);
            AIVehicle.SellVehicle(vehicle);
            break;

        default:
            Log.Error("An incorrect event was queued.", Log.LVL_INFO);
    }
}
