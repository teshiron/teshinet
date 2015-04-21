class Cargo
{

};

function Cargo::BuildCargoRoute(indStart, indEnd, cargoType, sourceIsTown = false, destIsTown = false)
{
    //Find a place for the source station
    AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);

    local startStationTile = -1;
    local endStationTile = -1;
    local startDepotTile = -1;
    local endDepotTile = -1;

    //build stations via SuperLib
    if (sourceIsTown)
    {
        startStationTile = Road.BuildStopInTown(indStart, AIRoad.ROADVEHTYPE_TRUCK, -1, cargoType);
    }
    else
    {
        startStationTile = Road.BuildStopForIndustry(indStart, cargoType);
    }

    if (destIsTown)
    {
        endStationTile = Road.BuildStopInTown(indEnd, AIRoad.ROADVEHTYPE_TRUCK, cargoType, -1);
    }
    else
    {
        endStationTile = Road.BuildStopForIndustry(indEnd, cargoType);
    }

    if (!startStationTile || !endStationTile) //BuildStopInTown returns "null" for failure
    {
        Log.Error("Either the start or ending station did not get built. Aborting.", Log.LVL_INFO);
        return -1;
    }

    local builder = RoadBuilder();

    builder.Init(startStationTile, endStationTile);
    local pathResult = builder.ConnectTiles();

    if (pathResult != 0)
    {
        Log.Error("Unable to connect stations. Aborting and removing stations.", Log.LVL_INFO);
        Station.DemolishStation(AIStation.GetStationID(startStationTile));
        Station.DemolishStation(AIStation.GetStationID(endStationTile));
        return -1
    }

    //build depots
    startDepotTile = Road.BuildDepotNextToRoad(startStationTile, 1, 500);
    endDepotTile = Road.BuildDepotNextToRoad(endStationTile, 1, 500);

    if (!startDepotTile) { startDepotTile = -1;} //AIMap.IsValidTile doesn't like null values
	if (!endDepotTile) { endDepotTile = -1; }
	
	if (!AIMap.IsValidTile(startDepotTile) || !AIMap.IsValidTile(endDepotTile))
    {
        Log.Error("Either the start or ending depot did not get built. Aborting.", Log.LVL_INFO);
        return -1;
    }

    //Now that the path is built, let's build some vehicles.
    local useDepot = null;

    if (AIRoad.IsRoadDepotTile(startDepotTile)) //in case one of the depots didn't get built
    {
        useDepot = startDepotTile;
    }
    else
    {
        useDepot = endDepotTile;
    }

    //We need to figure out which type of bus to buy.

    local vehList = AIEngineList(AIVehicle.VT_ROAD);
    local mustRefit = false;

    //only the buildable engines
    vehList.Valuate(AIEngine.IsBuildable);
    vehList.KeepValue(1);

    //and only road trucks, not trams
    vehList.Valuate(AIEngine.GetRoadType);
    vehList.KeepValue(AIRoad.ROADTYPE_ROAD);

    //now, only those suitable for this cargo
    vehList.Valuate(AIEngine.GetCargoType);
    vehList.KeepValue(cargoType);

    //but not articulated -- we're using pull in stations
    vehList.Valuate(AIEngine.IsArticulated);
    vehList.KeepValue(0);

    if (vehList.IsEmpty()) //No vehicles for this cargo?? Maybe we can refit one!
    {
        vehList = AIEngineList(AIVehicle.VT_ROAD); //repopulate

        //only the buildable engines
        vehList.Valuate(AIEngine.IsBuildable);
        vehList.KeepValue(1);

        //and only road trucks, not trams
        vehList.Valuate(AIEngine.GetRoadType);
        vehList.KeepValue(AIRoad.ROADTYPE_ROAD);

        //See if we can refit one of the truck types
        vehList.Valuate(AIEngine.CanRefitCargo, cargoType);
        vehList.KeepValue(1);

        //but not articulated -- we're using pull in stations
        vehList.Valuate(AIEngine.IsArticulated);
        vehList.KeepValue(0);

        //Do we have a winner?
        if (!vehList.IsEmpty())
        {
           mustRefit = true;
        }
        else
        {
           Log.Warning("No vehicles available for this type of route. Aborting.", Log.LVL_INFO);
           return -1;
        }
    }

    //we want the fastest type of vehicle.
    vehList.Valuate(AIEngine.GetMaxSpeed);
    vehList.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);

    local vehType = vehList.Begin(); //we'll build the one at the top of the list.
    local vehs = [];

    vehs.insert(0, AIVehicle.BuildVehicle(useDepot, vehType)); //build one truck of the right type in the desired depot

    if (!AIVehicle.IsValidVehicle(vehs[0]))
    {
        local errorCode = AIError.GetLastError();

        if (errorCode == AIVehicle.ERR_VEHICLE_TOO_MANY)
        {
            Log.Warning("Unable to create any vehicles for route; we've reached max road vehicles.", Log.LVL_INFO)
            this.at_max_RV_count = true;
            return -1;
        }
        else
        {
            Log.Error("Unable to create vehicles for route: unhandled error: " + AIError.GetLastErrorString(), Log.LVL_INFO);
            return -1;
        }
    }

    //refit if necessary
    if (mustRefit)
    {
        Log.Info("Refitting.", Log.LVL_DEBUG);
        AIVehicle.RefitVehicle(vehs[0], cargoType);
    }

    //give this truck orders
    AIOrder.AppendOrder(vehs[0], startStationTile, AIOrder.AIOF_FULL_LOAD_ANY);
    AIOrder.AppendOrder(vehs[0], endStationTile, (AIOrder.AIOF_UNLOAD | AIOrder.AIOF_NO_LOAD));

    for (local x = 1; x < 3; x++) //purchase subsequent trucks
    {
        vehs.push(AIVehicle.CloneVehicle(useDepot, vehs[0], true));
    }

    Log.Info("Vehicles purchased. Starting them.", Log.LVL_SUB_DECISIONS);

    for (local y = 0; y < 3; y++)
    {
        AIVehicle.StartStopVehicle(vehs[y]);
        TeshiNet.Sleep(1);
    }

    //make sure we don't use these industries again
    if (!sourceIsTown) this.industries_used.AddItem(indStart, AIIndustry.GetLocation(indStart));
    if (!destIsTown) this.industries_used.AddItem(indEnd, AIIndustry.GetLocation(indEnd));

    //record the station/industry mapping, for later closures etc.
    if (!sourceIsTown)
    {
        this.stations_by_industry.AddItem(indStart, AIStation.GetStationID(startStationTile));
        this.industries_by_station.AddItem(AIStation.GetStationID(startStationTile), indStart);
    }

    if (!destIsTown)
    {
        this.stations_by_industry.AddItem(indEnd, AIStation.GetStationID(endStationTile));
        this.industries_by_station.AddItem(AIStation.GetStationID(endStationTile), indEnd);
    }

    this.last_route_tick = TeshiNet.GetTick(); //record time of route creation

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

function Cargo::ManageBusyTruckStations()
{
    local masterList = AIList();
    local cargList = AICargoList();

    foreach (cargo, _ in cargList)
    {
        local stationList = AIStationList(AIStation.STATION_TRUCK_STOP); //make a list of stations

        stationList.Valuate(AIStation.GetCargoWaiting, cargo); //value them by cargo waiting
        stationList.KeepAboveValue(200); //let's increase if there's more than 200

        masterList.AddList(stationList);
    }

    if (masterList.IsEmpty()) // if the list is empty, then all stations are below 200 waiting cargo, no need to increase capacity
    {
        Log.Info("No truck stations with excessive waiting cargo.", Log.LVL_SUB_DECISIONS);
        return -1;
    }
    masterList.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING); //starting with the busiest station, since we might run out of cash

    foreach (curStation, _ in masterList)
    {
        local vehList = AIVehicleList_Station(curStation); //make a list of vehicles at this station, so we can count them

        local numveh = vehList.Count();

        local staTiles = AITileList_StationType(curStation, AIStation.STATION_TRUCK_STOP);

        local staSize = staTiles.Count();

        if ((numveh / 15.0) > staSize) //desired ratio is 1 station tile for every 15 vehicles or fraction thereof.
        {
            Log.Info("More than 15 vehicles per area at " + AIStation.GetName(curStation) + ". Building a new loading area at each end.", Log.LVL_SUB_DECISIONS);
            Road.GrowStation(curStation, AIStation.STATION_TRUCK_STOP);
            Road.GrowStation(this.station_pairs.GetValue(curStation), AIStation.STATION_TRUCK_STOP); //the other end of this route
        }

        CloneVehicleByStation(curStation);
    }
}