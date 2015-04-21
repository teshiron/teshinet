TeshiNet is an AI for OpenTTD written and maintained by Teshiron.

## v5.0 ##
In development.  You can test this version by checking out branch v5.

  * Now uses API version 1.1.
  * Freight delivery now goes to towns as well as industries, allowing cargoes such as mail, goods, food, and water.  Applies to both subsidies and random routes.
  * Planes are now handled by event system (crashes and unprofitability)
  * Plane routes now start with 4 aircraft instead of 2.
  * Route removal routines now just send the vehicles to a depot and do not wait for them to arrive.

Planned Enhancements:
  * Use API 1.5
  * Ensure route-seeking and subsidy routines filter out oil rigs (until/unless ships are implemented)
  * Advertise in the nearest town after a vehicle crash to raise cargo ratings
  * Implement plane upgrade/replacement when better vehicles are available

# Change Log: #

## v4.0.3 ##
Released 2015-04-20.  The master branch represents this version.

  * Because of the impending closure of Google Code, project is now hosted on GitHub. Links to Google Code revision numbers may stop working when that site closes.
  * Bugfix: crash at load due to requiring old version of SuperLib. Now depends on v38.
  * BaNaNaS update: Added PriorityQueue to the dependencies to prevent crashes.
  
## v4.0.1 ##
Released 2011-12-15 ([r47](https://code.google.com/p/teshinet/source/detail?r=47)+[r57](https://code.google.com/p/teshinet/source/detail?r=57))

  * Bugfix: crash at main.nut line 607 due to invalid parameters. Thanks to MAG101 for the bug report.

## v4.0 ##
Released 2011-12-12 ([r47](https://code.google.com/p/teshinet/source/detail?r=47)).

Version 4 breaks compatibility with older savegames.  v4 and up cannot load savegames from v3 and previous.

  * Implemented an event handler to detect crashed vehicles, unprofitable vehicles, and industry closures
  * Now searches periodically for available upgrades to road vehicles, and replaces the outdated vehicles
  * Now detects the location of an RV-hit-by-a-train crash, and replaces the level crossing with a bridge if possible
  * Also detects vehicles with invalid orders, along with vehicles missing orders entirely, and sells them
  * Now sets order flags for freight routes to avoid pickup at the destination station.
  * Restrict new passenger routes to towns above 500 population.
  * Removed unprofitable route check, since checking for individually unprofitable vehicles makes it redundant
  * Fixed a minor issue where the first route as a new company would never be built properly.
  * Modified the "enable buses" AI setting so changing it will actually take effect before reloading the game.
  * Removed profitability restriction on adding vehicles to routes, per suggestion from Lowkee33. Also now adds new trucks before buses (in case it runs out of money) as freight cargoes are generally worth more per unit than PAX.

## v3.0 ##
Released 2011-12-07 ([r25](https://code.google.com/p/teshinet/source/detail?r=25))

  * Many changes to early game route handling and construction to improve viability with more difficult settings -- thanks to Brumi for reporting this issue
  * Wait longer for vehicles to reach depot when destroying a road route
  * Now avoids goods subsidies, because the truck route builder can't handle towns yet
  * No longer adds vehicles to existing routes unless the new vehicle can pay for itself within 3 years
  * Amount required for autorenew lowered significantly, this should help prevent gobs of ancient road vehicles always breaking down
  * No longer loads identified cargo types from save file
  * Set default log level to minimum
