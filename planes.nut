class Planes
{ };

function Planes::BuildAirRoute()
{
    local airport_type;

    //TODO: improve this - do this in the constructor if possible and store the result (need event handler to detect changes)

    if (AIAirport.IsValidAirportType(AIAirport.AT_INTERCON))
    {
        airport_type = AIAirport.AT_INTERCON;
    }
    else
    {
        if (AIAirport.IsValidAirportType(AIAirport.AT_INTERNATIONAL))
        {
            airport_type = AIAirport.AT_INTERNATIONAL;
        }
        else
        {
            if (AIAirport.IsValidAirportType(AIAirport.AT_METROPOLITAN))
            {
                airport_type = AIAirport.AT_METROPOLITAN;
            }
            else
            {
                if (AIAirport.IsValidAirportType(AIAirport.AT_LARGE))
                {
                    airport_type = AIAirport.AT_LARGE;
                }
                else
                {
                    AILog.Warning("No valid large airport types available. Cannot build air route.");
                    return -1;
                }
            }
        }
    }


    Log.Info("Trying to build an airport route", Log.LVL_INFO);

    local airports = Planes.FindAirportPair(airport_type);

    if (airports == -1)
    {
        return -1;
    }

    /* Build the airports for real */
    if (!AIAirport.BuildAirport(airports[0], airport_type, AIStation.STATION_NEW)) {
        AILog.Error("Although the testing told us we could build 2 airports, it still failed on the first airport at tile " + airports[0] + ".");
        this.towns_used.RemoveItem(airports[2]);
        this.towns_used.RemoveItem(airports[3]);
        return -3;
    }
    if (!AIAirport.BuildAirport(airports[1], airport_type, AIStation.STATION_NEW)) {
        AILog.Error("Although the testing told us we could build 2 airports, it still failed on the second airport at tile " + airports[1] + ".");
        AIAirport.RemoveAirport(airports[0]);
        this.towns_used.RemoveItem(airports[2]);
        this.towns_used.RemoveItem(airports[3]);
        return -4;
    }

    local ret = Planes.BuildAircraft(airports[0], airports[1]);
    if (ret < 0) {
        AIAirport.RemoveAirport(airports[0]);
        AIAirport.RemoveAirport(airports[1]);
        this.towns_used.RemoveItem(airports[2]);
        this.towns_used.RemoveItem(airports[3]);
        return ret;
    }

    Log.Info("Done building a route", Log.LVL_INFO);
    return ret;
}

function Planes::ManageBusyAirports()
{
    local stationList = AIStationList(AIStation.STATION_AIRPORT); //make a list of stations

    stationList.Valuate(AIStation.GetCargoWaiting, this.passenger_cargo_id); //value them by passengers waiting
    stationList.KeepAboveValue(500); //let's increase if they're above 500
    stationList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_DESCENDING); //starting with the busiest station, since we might run out of cash

    if (stationList.IsEmpty()) // if the list is empty, then all stations are below 500 waiting cargo, no need to increase capacity
    {
        Log.Info("No airports with excessive waiting passengers.", Log.LVL_SUB_DECISIONS);
        return -1;
    }

    for (local curStation = stationList.Begin(); stationList.HasNext(); curStation = stationList.Next())
    {
        Log.Info("Adding an airplane to serve " + AIStation.GetName(curStation), Log.LVL_SUB_DECISIONS);
        local vehList = AIVehicleList_Station(curStation);
        vehList.Valuate(AIVehicle.GetProfitLastYear);
        vehList.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_DESCENDING);

        local toClone = vehList.Begin();
        if (AICompany.GetBankBalance(AICompany.COMPANY_SELF) > (2 * AIEngine.GetPrice(AIVehicle.GetEngineType(toClone))))
        {
            local veh = AIVehicle.CloneVehicle(AIAirport.GetHangarOfAirport(AIStation.GetLocation(curStation)), toClone, true);
            if (!AIVehicle.IsValidVehicle(veh))
            {
                this.at_max_plane_count = true;
            }
            else
            {
                AIVehicle.StartStopVehicle(veh);
            }
        }
    }
}

function Planes::FindAirportPair(airport_type)
{
    local airport_x, airport_y, airport_rad;
    local first = -1;
    local firstTown = -1;
    local second = -1;
    local secondTown = -1;
    local pair = [-1, -1];

    airport_x = AIAirport.GetAirportWidth(airport_type);
    airport_y = AIAirport.GetAirportHeight(airport_type);
    airport_rad = AIAirport.GetAirportCoverageRadius(airport_type);

    local town_list = AITownList();
    /* Remove all the towns we already used */
    town_list.RemoveList(this.towns_used);

    town_list.Valuate(AITown.GetPopulation);
    town_list.KeepAboveValue(500);
    /* Keep the best 30 */
    town_list.KeepTop(30);
    town_list.Valuate(AIBase.RandItem);

    /* Now find 2 suitable towns */
    for (local town = town_list.Begin(); town_list.HasNext(); town = town_list.Next())
    {
        /* Don't make this a CPU hog */
        Sleep(1);

        local tile = AITown.GetLocation(town);

        /* Create a 40x40 grid around the core of the town and see if we can find a spot for the airport */
        local list = AITileList();

        /* XXX -- We assume we are more than 20 tiles away from the border! */
        list.AddRectangle(tile - AIMap.GetTileIndex(20, 20), tile + AIMap.GetTileIndex(20, 20));
        list.Valuate(AITile.IsBuildableRectangle, airport_x, airport_y);
        list.KeepValue(1);


        /* Sort on acceptance, remove places that don't have acceptance */
        list.Valuate(AITile.GetCargoAcceptance, this.passenger_cargo_id, airport_x, airport_y, airport_rad);
        list.RemoveBelowValue(10);

        /* Couldn't find a suitable place for this town, skip to the next */
        if (list.Count() == 0) continue;

        /* Walk all the tiles and see if we can build the airport at all */
        {
            local test = AITestMode();
            local good_tile = 0;

            for (tile = list.Begin(); list.HasNext(); tile = list.Next())
            {
                Sleep(1);
                if (!AIAirport.BuildAirport(tile, airport_type, AIStation.STATION_NEW)) continue;
                good_tile = tile;
                break;
            }

            /* Did we found a place to build the airport on? */
            if (good_tile == 0) continue;
        }

        Log.Info("Found a good spot for an airport in town " + town, Log.LVL_SUB_DECISIONS);

        /* Make the town as used, so we don't use it again */

        first = tile;
        firstTown = town;
        break;
    }

    if (!AIMap.IsValidTile(first))
    {
        Log.Warning("Couldn't find a suitable first town to build an airport in", Log.LVL_INFO);
        return -1;
    }

    //Now let's look for a second town.

    town_list = AITownList();

    /* Remove all the towns we already used */
    town_list.RemoveList(this.towns_used);

    town_list.Valuate(TownDistance, AITown.GetLocation(firstTown));
    town_list.KeepBetweenValue(100, 250);

    town_list.Valuate(AITown.GetPopulation);
    town_list.KeepAboveValue(500);
    town_list.KeepTop(10);
    town_list.Valuate(AIBase.RandItem);

    /* Now find 2 suitable towns */
    for (local town = town_list.Begin(); town_list.HasNext(); town = town_list.Next())
    {
        /* Don't make this a CPU hog */
        Sleep(1);

        local tile = AITown.GetLocation(town);

        /* Create a 40x40 grid around the core of the town and see if we can find a spot for the airport */
        local list = AITileList();

        /* XXX -- We assume we are more than 15 tiles away from the border! */
        list.AddRectangle(tile - AIMap.GetTileIndex(20, 20), tile + AIMap.GetTileIndex(20, 20));
        list.Valuate(AITile.IsBuildableRectangle, airport_x, airport_y);
        list.KeepValue(1);


        /* Sort on acceptance, remove places that don't have acceptance */
        list.Valuate(AITile.GetCargoAcceptance, this.passenger_cargo_id, airport_x, airport_y, airport_rad);
        list.RemoveBelowValue(10);

        /* Couldn't find a suitable place for this town, skip to the next */
        if (list.Count() == 0) continue;

        /* Walk all the tiles and see if we can build the airport at all */
        {
            local test = AITestMode();
            local good_tile = 0;

            for (tile = list.Begin(); list.HasNext(); tile = list.Next())
            {
                Sleep(1);
                if (!AIAirport.BuildAirport(tile, airport_type, AIStation.STATION_NEW)) continue;
                good_tile = tile;
                break;
            }

            /* Did we found a place to build the airport on? */
            if (good_tile == 0) continue;
        }

        Log.Info("Found a good spot for an airport in " + town, Log.LVL_SUB_DECISIONS);

        /* Mark the town as used, so we don't use it again */

        second = tile;
        secondTown = town;
        break;
    }

    if (second != null)
    {
        if (!AIMap.IsValidTile(second))
        {
            Log.Warning("Couldn't find a suitable second town to build an airport in", Log.LVL_INFO);
            return -1;
        }
    }
    else
    {
        Log.Warning("Couldn't find a suitable second town to build an airport in", Log.LVL_INFO);
        return -1;
    }

    this.towns_used.AddItem(firstTown, 1);
    this.towns_used.AddItem(secondTown, 1);

    pair = [first, second, firstTown, secondTown]
    return pair;

}

function Planes::BuildAircraft(tile_1, tile_2)
{
    /* Build an aircraft */
    local hangar = AIAirport.GetHangarOfAirport(tile_1);
    local hangar2 = AIAirport.GetHangarOfAirport(tile_2);
    local engine = null;

    local engine_list = AIEngineList(AIVehicle.VT_AIR);

    /* When bank balance < 300000, buy cheaper planes */
    local balance = AICompany.GetBankBalance(AICompany.COMPANY_SELF);
    engine_list.Valuate(AIEngine.GetPrice);
    engine_list.KeepBelowValue(balance < 300000 ? 50000 : (balance < 1000000 ? 300000 : 1000000));

    engine_list.Valuate(AIEngine.GetCargoType);
    engine_list.KeepValue(this.passenger_cargo_id);

    engine_list.Valuate(AIEngine.GetCapacity);
    engine_list.KeepTop(1);

    engine = engine_list.Begin();

    if (!AIEngine.IsValidEngine(engine)) {
        AILog.Error("Couldn't find a suitable engine");
        return -5;
    }

    local plane1 = AIVehicle.BuildVehicle(hangar, engine);

    if (!AIVehicle.IsValidVehicle(plane1))
        {
            AILog.Error("Couldn't build the aircraft. Error " + AIError.GetLastError());
            return -6;
        }

    /* Send him on his way */

    AIOrder.AppendOrder(plane1, tile_1, AIOrder.AIOF_NONE);
    AIOrder.AppendOrder(plane1, tile_2, AIOrder.AIOF_NONE);
    AIVehicle.StartStopVehicle(plane1);

    local plane3 = AIVehicle.CloneVehicle(hangar, plane1, true);
    AIVehicle.StartStopVehicle(plane3);

    local plane2 = AIVehicle.BuildVehicle(hangar2, engine);

    if (!AIVehicle.IsValidVehicle(plane2))
    {
        AILog.Error("Couldn't build the aircraft");
        this.at_max_plane_count = true;
        return -6;
    }

    /* Send him on his way */

    AIOrder.AppendOrder(plane2, tile_2, AIOrder.AIOF_NONE);
    AIOrder.AppendOrder(plane2, tile_1, AIOrder.AIOF_NONE);
    AIVehicle.StartStopVehicle(plane2);

    local plane4 = AIVehicle.CloneVehicle(hangar2, plane2, true);
    AIVehicle.StartStopVehicle(plane4);

    Log.Info("Done building 4 aircraft", Log.LVL_SUB_DECISIONS);

    return 0;
}

function Planes::RemoveUnprofPlanes()
{
    //TODO: make this just remove the route, like road vehicles?

    Log.Info("Sending unprofitable planes to the hangar.", Log.LVL_SUB_DECISIONS);
    local planeList = AIVehicleList();

    planeList.Valuate(AIVehicle.GetVehicleType);
    planeList.KeepValue(AIVehicle.VT_AIR);

    planeList.Valuate(AIVehicle.GetState);
    planeList.RemoveValue(AIVehicle.VS_IN_DEPOT);
    planeList.RemoveValue(AIVehicle.VS_CRASHED);
    planeList.RemoveValue(AIVehicle.VS_STOPPED);

    planeList.Valuate(AIVehicle.GetAge);
    planeList.KeepAboveValue(365*2);

    local success = false;
    local count = 0;

    for (local plane = planeList.Begin(); planeList.HasNext(); plane = planeList.Next())
    {
        if (AIVehicle.GetProfitLastYear(plane) < 10000)
        {
            do
            {
                success = AIVehicle.SendVehicleToDepot(plane);
                this.Sleep(1);
            } while (!success)
            count++;
        }
    }

    Log.Info("Sent " + count + " planes to the hangar.", Log.LVL_SUB_DECISIONS);
}

function Planes::SellStoppedPlanes()
{
    Log.Info("Selling planes stopped in the hangar.", Log.LVL_SUB_DECISIONS);
    local planeList = AIVehicleList();

    planeList.Valuate(AIVehicle.GetVehicleType);
    planeList.KeepValue(AIVehicle.VT_AIR);

    planeList.Valuate(AIVehicle.GetState);
    planeList.KeepValue(AIVehicle.VS_IN_DEPOT);

    local count = 0;

    for (local plane = planeList.Begin(); planeList.HasNext(); plane = planeList.Next())
    {
        if (AIVehicle.SellVehicle(plane))
        {
            count++;
        }
    }

    Log.Info("Sold " + count + " planes.", Log.LVL_SUB_DECISIONS);

}

function Planes::RemoveUnusedAirports()
{
    Log.Info("Removing unused airports.", Log.LVL_SUB_DECISIONS);
    local stationList = AIStationList(AIStation.STATION_AIRPORT);

    for (local curSta = stationList.Begin(); stationList.HasNext(); curSta = stationList.Next())
    {
        local stationVehs = AIVehicleList_Station(curSta);

        if (stationVehs.IsEmpty())
        {
            Log.Info(AIStation.GetName(curSta) + " is not in use. Removing.", Log.LVL_SUB_DECISIONS);
            AIAirport.RemoveAirport(AIBaseStation.GetLocation(curSta));
        }
        this.Sleep(1);
    }
}

function Planes::RemoveUnprofRoute() //do we actually use this function anywhere?
{
    Log.Info("Searching for least profitable air route for removal.", Log.LVL_INFO);

    local routeProfits = AIList(); //create a list to store the average profit of each route

    local staList = AIStationList(AIStation.STATION_AIRPORT);

    for (local route = staList.Begin(); staList.HasNext(); route = staList.Next()) //iterate through our bus stations
    {
        local vehicles = AIVehicleList_Station(route);

        if (vehicles.IsEmpty()) continue;

        vehicles.Valuate(AIVehicle.GetAge); //how old are they?
        vehicles.KeepAboveValue(365 * 2); //we only want to calculate on vehicles that have had two full years to run. this ensures last year's profit is a full year.

        if (vehicles.IsEmpty()) continue; //young route? give it a chance.

        vehicles.Valuate(AIVehicle.GetProfitLastYear);

        local revenuetotal = 0;
        local meanprofit = 0;

        for (local veh = vehicles.Begin(); vehicles.HasNext(); veh = vehicles.Next())
        {
            revenuetotal += vehicles.GetValue(veh);
        }

        local meanprofit = revenuetotal / vehicles.Count(); //calculate the mean profit (total revenue divided by total vehicle count)

        routeProfits.AddItem(route, meanprofit); //add this route with profit total to the list.

    }
    routeProfits.Sort(AIAbstractList.SORT_BY_VALUE, AIAbstractList.SORT_ASCENDING); //the route at the top is our least profitable by vehicle

    local deadRoute = routeProfits.Begin(); //this is the station index of the first station on the least profitable route.

    /* if (routeProfits.GetValue(deadRoute) >= 10000) //min profit to score, $20,000 or 10,000 pounds
    {
        Log.Info("Our least profitable road route is earning over 10,000 pounds per vehicle. Aborting removal.");
        return -1;
    }  almost all air routes will be over 10K pounds, this is meaningless */

    local deadRouteStart = deadRoute;
    local deadVehicles = AIVehicleList_Station(deadRoute);

    local tempveh = deadVehicles.Begin();

    local otherEnd = AIStationList_Vehicle(tempveh);
    local tempEnd = AIList();

    tempEnd.AddItem(deadRouteStart, 1);
    otherEnd.RemoveList(tempEnd);
    local deadRouteEnd = otherEnd.Begin();

    Log.Info("The route from " + AIStation.GetName(deadRouteStart) + " to " + AIStation.GetName(deadRouteEnd) + " is our least profitable route per vehicle. Killing this route.");
    Log.Info("The average profit per vehicle last year was " + routeProfits.GetValue(deadRoute) + " (pounds) on this route.");



    Log.Info("Sending vehicles to depot and selling them.");

    local tempList = AIList(); //a list for vehicles which fail to get sent

    for (local curVeh = deadVehicles.Begin(); deadVehicles.HasNext(); curVeh = deadVehicles.Next())
    {
        local success = AIVehicle.SendVehicleToDepot(curVeh);

        if (!success)
        {
            tempList.AddItem(curVeh, 1)
        }
    }

    this.Sleep(100); //give them some time to get there
    local timeout = 0;

    if (!tempList.IsEmpty())
    {
        Log.Info(tempList.Count() + " vehicles didn't get the depot order.  Trying again.");

        for (local curtVeh = tempList.Begin(); tempList.HasNext(); curtVeh = tempList.Next())
        {
            local succeed = false;


            if (!AIVehicle.IsStoppedInDepot(curtVeh))
            {
                while (!succeed)
                {
                    succeed = AIVehicle.SendVehicleToDepot(curtVeh);
                    this.Sleep(2);

                }
            }
            else
            {
                continue;
            }
        }
    }

    do
    {
        deadVehicles.Valuate(AIVehicle.IsStoppedInDepot);
        deadVehicles.KeepValue(1);

        for (local curVeh = deadVehicles.Begin(); deadVehicles.HasNext(); curVeh = deadVehicles.Next())
        {
            AIVehicle.SellVehicle(curVeh);
        }

        deadVehicles = AIVehicleList_Station(deadRoute);

        this.Sleep(25); //give the rest some more time
        timeout++;

    } while (!deadVehicles.IsEmpty() && timeout < 45)

    if (!deadVehicles.IsEmpty())
    { //once more, with feeling!
        Log.Info("Seems that not all of the vehicles made it to the depot. We'll try one more time.");

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

            this.Sleep(25); //give the rest some more time
            timeout++;

        } while (!deadVehicles.IsEmpty() && timeout < 45)
    }


    Log.Info("Vehicles sold; removing stations.");

    this.towns_used.RemoveItem(AITile.GetClosestTown(AIStation.GetLocation(deadRouteStart)));
    this.towns_used.RemoveItem(AITile.GetClosestTown(AIStation.GetLocation(deadRouteEnd)));

    AIAirport.RemoveAirport(AIStation.GetLocation(deadRouteStart));
    AIAirport.RemoveAirport(AIStation.GetLocation(deadRouteEnd));

    return 1;
}