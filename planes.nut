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

    Log.Info("Trying to build an air route", Log.LVL_INFO);

    local air_pair = Planes.FindAirPair();

    switch (air_pair)
    {
        case -1:
            Log.Error("Unable to find a first town for route.");
            return -1;
            break;
        case -2:
            Log.Error("Unable to find a second town for route.");
            return -1;
            break;
        default:
            break;
    }

    local airportLoc1 = Airport.BuildAirportInTown(air_pair[0], airport_type, this.passenger_cargo_id);
    local airportLoc2 = null;

    if (airportLoc1)
    {
        airportLoc2 = Airport.BuildAirportInTown(air_pair[1], airport_type, this.passenger_cargo_id);
    }
    else
    {
        Log.Info("Failed to build first airport. Will try again later with a different town pair.", Log.LVL_INFO);
        return -1;
    }

    if (airportLoc2)
    {
        local built = Planes.BuildAircraft(airportLoc1, airportLoc2);
        if (built == 0)
        {
            this.station_pairs.AddItem(AIStation.GetStationID(airportLoc1), AIStation.GetStationID(airportLoc2));
            this.station_pairs.AddItem(AIStation.GetStationID(airportLoc2), AIStation.GetStationID(airportLoc1));
            this.towns_used.AddItem(air_pair[0], 1);
            this.towns_used.AddItem(air_pair[1], 1);
        }
        else
        {
            Log.Error("Failed to build aircraft.");
            AIAirport.RemoveAirport(airportLoc1);
            AIAirport.RemoveAirport(airportLoc2);
            return -1;
        }
    }
    else
    {
        Log.Error("Failed to build second airport. Will try again later with a different town pair.", Log.LVL_INFO);
        AIAirport.RemoveAirport(airportLoc1);
    }

    Log.Info("Done building an air route", Log.LVL_INFO);
    return 1;
}

function Planes::ManageBusyAirports()
{
    local stationList = AIStationList(AIStation.STATION_AIRPORT); //make a list of stations

    stationList.Valuate(AIStation.GetCargoWaiting, this.passenger_cargo_id); //value them by passengers waiting
    stationList.KeepAboveValue(500); //let's increase if they're above 500
    stationList.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING); //starting with the busiest station, since we might run out of cash

    if (stationList.IsEmpty()) // if the list is empty, then all stations are below 500 waiting cargo, no need to increase capacity
    {
        Log.Info("No airports with excessive waiting passengers.", Log.LVL_SUB_DECISIONS);
        return -1;
    }

    foreach (curStation, _ in stationList)
    {
        Log.Info("Adding an airplane to serve " + AIStation.GetName(curStation), Log.LVL_SUB_DECISIONS);
        local vehList = AIVehicleList_Station(curStation);
        vehList.Valuate(AIVehicle.GetProfitLastYear);
        vehList.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);

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
    foreach (town, _ in town_list)
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

            foreach (tile, _ in list)
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
    foreach (town in town_list)
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

            foreach (tile in list)
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

    foreach (plane, _ in planeList)
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

    foreach (plane, _ in planeList)
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

    foreach (curSta, _ in stationList)
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

function Planes::FindAirPair()
{
    local townList = AITownList();
    local first = null;
    local second = null;

    townList.Valuate(AITown.GetPopulation);
    townList.KeepAboveValue(999); //only build airports in towns over 1K population

    townList.Valuate(AITown.GetAllowedNoise);
    townList.KeepAboveValue(0); //eliminate any towns which will not allow more airports

    townList.RemoveList(this.towns_used); //remove any towns we already service

    if (townList.IsEmpty()) return -1;

    townList.Valuate(AIBase.RandItem);
    townList.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING); //randomize the list

    first = townList.Begin(); //get the top one, that is our first town
    townList.RemoveItem(first); //take it off the list

    townList.Valuate(TownDistance, AITown.GetLocation(first)); //valuate by distance from the first town
    townList.KeepBetweenValue(100, 250); //Keep those between 100-250 tiles away

    if (townList.IsEmpty()) return -2;

    townList.Valuate(AIBase.RandItem);
    townList.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING); //randomize the list

    second = townList.Begin(); //get the top one, that's the second town

    return [first, second];
}