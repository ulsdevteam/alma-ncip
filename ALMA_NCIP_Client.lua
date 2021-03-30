--About ALMA_NCIP_Client 7.0
--
--To be used with ULS-updated PrimoVE.lua addon, with delimited Alma barcodes and request IDs stored in ItemInfo1 and ItemInfo2 fields.
--Lending CheckOut (triggered by In Stacks Searching 'Mark Found' cancels pending Patron Physical Item Requests via API and checks out the item via NCIP.
--Lending CheckIn (triggered by Lending Returns processing 'Process Queue' performs NCIP checkin and barcode scan-in via API to correctly reflect the item's location at the Resource Sharing library.
--
--Modified for ULS by: Jason Thorhauer, jat188@.edu
--Modified by: Tom McNulty, VCU Libraries, tmcnulty@vcu.edu
--Original Author:  Bill Jones III, SUNY Geneseo, IDS Project, jonesw@geneseo.edu


--System Addon used for ILLiad to communicate with Alma through NCIP protocol
--
--Description of Registered Event Handlers for ILLiad
--
--BorrowingRequestCheckedInFromLibrary 
--This will trigger whenever a non-cancelled transaction is processed from the Check In From Lending Library 
--batch processing form using the Check In, Check In Scan Now, or Check In Scan Later buttons.
--
--BorrowingRequestCheckedInFromCustomer
--This will trigger whenever an item is processed from the Check Item In batch processing form, 
--regardless of its status (such as if it were cancelled or never picked up by the customer).
--
--LendingRequestCheckOut
--This will trigger whenever a transaction is processed from the Lending Update Stacks Searching form 
--using the Mark Found or Mark Found Scan Now buttons. This will also work on the Lending Processing ribbon
--of the Request form for the Mark Found and Mark Found Scan Now buttons. Cancels pending Alma Patron Physical Item Request and checks out item
--
--LendingRequestCheckIn
--This will trigger whenever a transaction is processed from the Lending Returns batch processing form.
--Checks in item via NCIP and performs wand-in at Resource Sharing location
--
--Queue names have a limit of 40 characters (including spaces).




local Settings = {};
Settings.DebugMode = GetSetting("DebugMode");

--NCIP Responder URL
if (Settings.DebugMode == true) then
	LogDebug("Alma NCIP: Debug mode is on - NCIP and API requests will act on the sandbox");
	Settings.NCIP_Responder_URL = GetSetting("Sandbox_NCIP_Responder_URL");
	Settings.APIKey = GetSetting("SandboxAPIKey");
else
	LogDebug("Alma NCIP: Debug mode is off - NCIP and API requests will act on production");
	Settings.NCIP_Responder_URL = GetSetting("Production_NCIP_Responder_URL");
	Settings.APIKey = GetSetting("ProductionAPIKey");
end

-- Add trailing slash to APIEndpoint if not present
Settings.APIEndpoint = GetSetting("APIEndpoint");
lastChar = string.sub(Settings.APIEndpoint, -1);
if (lastChar ~= "/") then 
	Settings.APIEndpoint = Settings.APIEndpoint .. "/"; 
end 

--Change Prefix Settings for Transactions
Settings.Use_Prefixes = GetSetting("Use_Prefixes");
Settings.Prefix_for_LibraryUseOnly = GetSetting("Prefix_for_LibraryUseOnly");
Settings.Prefix_for_RenewablesAllowed = GetSetting("Prefix_for_RenewablesAllowed");
Settings.Prefix_for_LibraryUseOnly_and_RenewablesAllowed = GetSetting("Prefix_for_LibraryUseOnly_and_RenewablesAllowed");

--NCIP Error Status Changes
Settings.BorrowingAcceptItemFailQueue = GetSetting("BorrowingAcceptItemFailQueue");
Settings.BorrowingCheckInItemFailQueue = GetSetting("BorrowingCheckInItemFailQueue");
Settings.LendingCheckOutItemFailQueue = GetSetting("LendingCheckOutItemFailQueue");
Settings.LendingCheckInItemFailQueue = GetSetting("LendingCheckInItemFailQueue");

--acceptItem settings
Settings.acceptItem_from_uniqueAgency_value = GetSetting("acceptItem_from_uniqueAgency_value");
Settings.acceptItem_Transaction_Prefix = GetSetting("checkInItem_Transaction_Prefix");

--checkInItem settings
Settings.ResourceSharingLibraryCode = GetSetting("ResourceSharingLibraryCode");
Settings.ResourceSharingCirculationDeskCode = GetSetting("ResourceSharingCirculationDeskCode");
Settings.checkInItem_EnablePatronBorrowingReturns = GetSetting("EnablePatronBorrowingReturns");
Settings.ApplicationProfileType = GetSetting("ApplicationProfileType");
Settings.checkInItem_Transaction_Prefix = GetSetting("checkInItem_Transaction_Prefix");


--checkOutItem settings
Settings.PseudopatronID = GetSetting("PseudopatronID");
Settings.checkOutItem_RequestIdentifierValue_Prefix = GetSetting("checkOutItem_RequestIdentifierValue_Prefix");
Settings.ILLiad_NCIP_Agency_value = GetSetting("ILLiad_NCIP_Agency_value");

function Init()
	RegisterSystemEventHandler("BorrowingRequestCheckedInFromLibrary", "BorrowingAcceptItem");
	RegisterSystemEventHandler("BorrowingRequestCheckedInFromCustomer", "BorrowingCheckInItem");
	RegisterSystemEventHandler("LendingRequestCheckOut", "LendingCheckOutItem");
	RegisterSystemEventHandler("LendingRequestCheckIn", "LendingCheckInItem");
end

--Borrowing Functions
function BorrowingAcceptItem(transactionProcessedEventArgs)
	LogDebug("BorrowingAcceptItem - start");
	
	if GetFieldValue("Transaction", "RequestType") == "Loan" then
		local pieces = CountPieces();
		local currentTN = GetFieldValue("Transaction", "TransactionNumber");
		
		if (pieces == 1) then
			SetFieldValue("Transaction","ItemInfo1",currentTN..'-1OF1');
		else
			SetFieldValue("Transaction","ItemInfo1",currentTN..'-XOF'..pieces);
		end
		
		LogDebug("Alma NCIP:Item Request has been identified as a Loan and not Article - process started with " .. pieces .. " pieces.");
		
		for i=0,pieces-1 do
			luanet.load_assembly("System");
			local ncipAddress = Settings.NCIP_Responder_URL;
			local BAImessage = buildAcceptItem(i+1,pieces);
			LogDebug("Alma NCIP:creating BorrowingAcceptItem message[" .. BAImessage .. "]");
			local WebClient = luanet.import_type("System.Net.WebClient");
			local myWebClient = WebClient();
			LogDebug("Alma NCIP:WebClient Created");
			LogDebug("Alma NCIP:Adding Header");

			LogDebug("Setting Upload String");
			local BAIresponseArray = myWebClient:UploadString(ncipAddress, BAImessage);
			LogDebug("Alma NCIP:Upload response was[" .. BAIresponseArray .. "]");
			
			LogDebug("Starting error catch")
			local currentTN = GetFieldValue("Transaction", "TransactionNumber");
			
			if string.find (BAIresponseArray, "Item Not Checked Out") then
			LogDebug("NCIP Error: Item Not Checked Out");
			ExecuteCommand("Route", {currentTN, "NCIP Error: BorAcceptItem-NotCheckedOut"});
			LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
			ExecuteCommand("AddNote", {currentTN, BAIresponseArray});
			SaveDataSource("Transaction");
			
			elseif string.find(BAIresponseArray, "User Authentication Failed") then
			LogDebug("NCIP Error: User Authentication Failed");
			ExecuteCommand("Route", {currentTN, "NCIP Error: BorAcceptItem-UserAuthFail"});
			LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
			ExecuteCommand("AddNote", {currentTN, BAIresponseArray});
			SaveDataSource("Transaction");
			
			--this error came up from non-standard characters in the title (umlauts)
			elseif string.find(BAIresponseArray, "Service is not known") then
			LogDebug("NCIP Error: ReRouting Transaction");
			ExecuteCommand("Route", {currentTN, "NCIP Error: BorAcceptItem-SrvcNotKnown"});
			LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
			ExecuteCommand("AddNote", {currentTN, BAIresponseArray});
			SaveDataSource("Transaction");	

			elseif string.find(BAIresponseArray, "Problem") then
			LogDebug("NCIP Error: ReRouting Transaction");
			ExecuteCommand("Route", {currentTN, Settings.BorrowingAcceptItemFailQueue});
			LogDebug("Adding Note to Transaction with NCIP Client Error");
			ExecuteCommand("AddNote", {currentTN, BAIresponseArray});
			SaveDataSource("Transaction");
			
			else
			LogDebug("Alma NCIP:No Problems found in NCIP Response.")
			ExecuteCommand("AddNote", {currentTN, "NCIP Response for BorrowingAcceptItem received successfully"});
			SaveDataSource("Transaction");
			end
			
		end --end of pieces loop
	end
end


function BorrowingCheckInItem(transactionProcessedEventArgs)
	local pieces = CountPieces();
	LogDebug("Alma NCIP:BorrowingCheckInItem - start for " .. pieces .. " pieces.");
	
	for i=0,pieces-1 do
		luanet.load_assembly("System");
		local ncipAddress = Settings.NCIP_Responder_URL;
		local BCIImessage = buildCheckInItemBorrowing(i+1,pieces);
		LogDebug("Alma NCIP:creating BorrowingCheckInItem message[" .. BCIImessage .. "]");
		local WebClient = luanet.import_type("System.Net.WebClient");
		local myWebClient = WebClient();
		LogDebug("Alma NCIP:WebClient Created");
		LogDebug("Alma NCIP:Adding Header");
		myWebClient.Headers:Add("Content-Type", "text/xml; charset=UTF-8");
		LogDebug("Alma NCIP:Setting Upload String");
		local BCIIresponseArray = myWebClient:UploadString(ncipAddress, BCIImessage);
		LogDebug("Upload response was[" .. BCIIresponseArray .. "]");
		
		LogDebug("Starting error catch")
		local currentTN = GetFieldValue("Transaction", "TransactionNumber");
		
		if string.find(BCIIresponseArray, "Unknown Item") then
			LogDebug("NCIP checkin failed: Unknown Item: [" .. BCIIresponseArray .. "]");
			
			---------LEGACY NCIP checkins will not have the same barcode format, so retry checkin with just TN as barcode ------------------
			local Legacymessage = buildLegacyCheckInItemBorrowing(currentTN);
			local BCIIresponseArray = myWebClient:UploadString(ncipAddress, Legacymessage);
				if string.find(BCIIresponseArray, "Unknown Item") then
					LogDebug("NCIP checkin failed on retry for legacy barcode as well: [" .. BCIIresponseArray .. "]");
					LogDebug("NCIP Error: ReRouting Transaction");
					ExecuteCommand("Route", {currentTN, "NCIP Error: BorCheckIn-UnknownItem"});
					LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
					ExecuteCommand("AddNote", {currentTN, BCIIresponseArray});
					SaveDataSource("Transaction");
				else
					LogDebug("No Problems found in NCIP retry with legacy barcode.")
					ExecuteCommand("AddNote", {currentTN, "NCIP Response for BorrowingCheckInItem (legacy) received successfully"});
					SaveDataSource("Transaction");
				end

			-----------------------------------------------------------------------------------------------------------------------------------------
		
		
		elseif string.find(BCIIresponseArray, "Item Not Checked Out") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, "NCIP Error: BorCheckIn-NotCheckedOut"});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, BCIIresponseArray});
		SaveDataSource("Transaction");
		
		elseif string.find(BCIIresponseArray, "Problem") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, Settings.BorrowingCheckInItemFailQueue});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, BCIIresponseArray});
		SaveDataSource("Transaction");
		
		else
		LogDebug("No Problems found in NCIP Response.")
		ExecuteCommand("AddNote", {currentTN, "NCIP Response for BorrowingCheckInItem received successfully"});
		SaveDataSource("Transaction");
		end
	end -- end of pieces loop
end

--Lending Functions

function CancelPendingRequests(request)
-- cancels Patron Physical Item Request via API before attempting checkOutItem

local requestID = request;
local tn = GetFieldValue("Transaction", "TransactionNumber");
local APIAddress = Settings.APIEndpoint .. 'users/' .. Settings.PseudopatronID .. '/requests/' .. requestID .. '?apikey=' .. Settings.APIKey .. '&notify_user=false&reason=RequestSwitched';


LogDebug('AlmaNCIP:Attempting to use API Endpoint '.. APIAddress);
luanet.load_assembly("System");
local WebClient = luanet.import_type("System.Net.WebClient");
local APICancelWebClient = WebClient();
LogDebug("Alma NCIP:WebClient Created");
LogDebug("Alma NCIP:Adding Header");
		
APICancelWebClient.Headers:Add("Content-Type", "application/xml;charset=UTF-8");
local APICancelresponseArray = "";

if pcall(function () APICancelresponseArray = APICancelWebClient:UploadString(APIAddress, "DELETE", ""); end) then
	LogDebug("AlmaNCIP: API Request Cancel response was[" .. APICancelresponseArray .. "]");
	ExecuteCommand("AddNote", {tn, 'Patron Physical Item Request ' .. requestID .. ' cancelled via API', 'System'});
else
	LogDebug("AlmaNCIP: API failure - unable to cancel request # " .. requestID);
	ExecuteCommand("AddNote", {tn, 'API Failure: unable to cancel Alma Patron Physical Item Request ' .. requestID, 'System'});
end

end

function LendingCheckOutItem(transactionProcessedEventArgs)
	LogDebug("DEBUG -- LendingCheckOutItem - start");
	luanet.load_assembly("System");
	local i=0;
	local requests = {};
	local barcodes = {};
	
	local requestdatafield = GetFieldValue("Transaction","ItemInfo2");
	
	if (GetFieldValue("Transaction","ItemInfo1")) == '' then
		LogDebug("AlmaNCIP: ItemInfo1 field blank - using legacy ItemNumber field for checkout");
		SetFieldValue("Transaction","ItemInfo1",GetFieldValue("Transaction","ItemNumber"));
	end
	
	local barcodedatafield = GetFieldValue("Transaction","ItemInfo1");
		
	local requests = Parse(requestdatafield,'/');
	local barcodes = Parse(barcodedatafield,'/');
	
	
	for i = 0,(#barcodes)-1  do
		
		-- cancel Patron Physical Item Request via API before attempting checkOutItem
		-- items requested without this plugin may not have pending requests
		if (#requests ~= #barcodes) then
			LogDebug("# requests does not match # barcodes.");
		else
			CancelPendingRequests((requests[i+1]));
		end
		
		
		local ncipAddress = Settings.NCIP_Responder_URL;
		local LCOImessage = buildCheckOutItem((barcodes[i+1]));
		LogDebug("creating LendingCheckOutItem message[" .. LCOImessage .. "]");
		local WebClient = luanet.import_type("System.Net.WebClient");
		local myWebClient = WebClient();
		LogDebug("Alma NCIP:WebClient Created");
		LogDebug("Alma NCIP:Adding Header");
		myWebClient.Headers:Add("Content-Type", "text/xml; charset=UTF-8");
		LogDebug("Alma NCIP:Setting Upload String");
		local LCOIresponseArray = myWebClient:UploadString(ncipAddress, LCOImessage);
		LogDebug("Upload response was[" .. LCOIresponseArray .. "]");
		
		LogDebug("Starting error catch")
		local currentTN = GetFieldValue("Transaction", "TransactionNumber");
		

		if string.find(LCOIresponseArray, "Apply to circulation desk - Loan cannot be renewed (no change in due date)") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckOut-No Change Due Date"});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, LCOIresponseArray});
		SaveDataSource("Transaction");
		
		elseif string.find(LCOIresponseArray, "User Ineligible To Check Out This Item") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckOut-User Ineligible"});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, LCOIresponseArray});
		SaveDataSource("Transaction");
		
		elseif string.find(LCOIresponseArray, "User Unknown") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckOut-User Unknown"});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, LCOIresponseArray});
		SaveDataSource("Transaction");
		
		elseif string.find(LCOIresponseArray, "Problem") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, Settings.LendingCheckOutItemFailQueue});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, LCOIresponseArray});
		SaveDataSource("Transaction");
		
		else
		LogDebug("Alma NCIP:No Problems found in NCIP Response.")
		ExecuteCommand("AddNote", {currentTN, "NCIP Response for LendingCheckOutItem received successfully"});
		SaveDataSource("Transaction");
		end
		
	end --end of barcodes iteration
end



function LendingCheckInItem(transactionProcessedEventArgs)
	local i=0;
	local requests = {};
	local barcodes = {};
	
	if (GetFieldValue("Transaction","ItemInfo1")) == '' then
		LogDebug("AlmaNCIP: ItemInfo1 field blank - using legacy ItemNumber field for checkin");
		SetFieldValue("Transaction","ItemInfo1",GetFieldValue("Transaction","ItemNumber"));
	end
	
	local barcodedatafield = GetFieldValue("Transaction","ItemInfo1");
		
	local barcodes = Parse(barcodedatafield,'/');

	for i=0,(#barcodes)-1 do
	
		LogDebug("Alma NCIP:LendingCheckInItem - start");
		luanet.load_assembly("System");
		local ncipAddress = Settings.NCIP_Responder_URL;
		local LCIImessage = buildCheckInItemLending((barcodes[i+1]));
		LogDebug("Alma NCIP:creating LendingCheckInItem message[" .. LCIImessage .. "]");
		local WebClient = luanet.import_type("System.Net.WebClient");
		local myWebClient = WebClient();
		LogDebug("Alma NCIP:WebClient Created");
		LogDebug("Alma NCIP:Adding Header");
		myWebClient.Headers:Add("Content-Type", "text/xml; charset=UTF-8");
		LogDebug("Alma NCIP:Setting Upload String");
		local LCIIresponseArray = myWebClient:UploadString(ncipAddress, LCIImessage);
		LogDebug("Alma NCIP:Upload response was[" .. LCIIresponseArray .. "]");

		LogDebug("Starting error catch")
		local currentTN = GetFieldValue("Transaction", "TransactionNumber");
		
		if string.find(LCIIresponseArray, "Unknown Item") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckIn-Unknown Item"});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, LCIIresponseArray});
		SaveDataSource("Transaction");
		
		elseif string.find(LCIIresponseArray, "Item Not Checked Out") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckIn-Not Checked Out"});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, LCIIresponseArray});
		SaveDataSource("Transaction");	
		
		elseif string.find(LCIIresponseArray, "Problem") then
		LogDebug("NCIP Error: ReRouting Transaction");
		ExecuteCommand("Route", {currentTN, Settings.LendingCheckInItemFailQueue});
		LogDebug("Alma NCIP:Adding Note to Transaction with NCIP Client Error");
		ExecuteCommand("AddNote", {currentTN, LCIIresponseArray});
		SaveDataSource("Transaction");
		
		else
		LogDebug("No Problems found in NCIP Response.")
		ExecuteCommand("AddNote", {currentTN, "NCIP Response for LendingCheckInItem received successfully"});
		SaveDataSource("Transaction");
		end
		
		-- Wanding in item at Resource Sharing library updates item location.  NCIP checkin erroneously shows item as 'available' at the original holding library.
		-- This step informs Alma that the item is still at Resource Sharing pending transit home.
		
		WandIn(barcodes[i+1]);
	end --end of barcode iterative loop
end

function GetHoldingData(barcode)
-- Returns mms_id, holding_id, and pid via API using item barcode

local itembarcode = barcode;
local APIAddress = Settings.APIEndpoint ..'items?item_barcode=' .. itembarcode .. '&apikey=' .. Settings.APIKey
LogDebug('Alma NCIP:Attempting to use API endpoint ' .. APIAddress);
LogDebug('Alma NCIP:API holding lookup for barcode ' .. itembarcode);

luanet.load_assembly("System");
local APIWebClient = luanet.import_type("System.Net.WebClient");
local streamreader = luanet.import_type("System.Net.IO.StreamReader");
local ThisWebClient = APIWebClient();

local APIResults = ThisWebClient:DownloadString(APIAddress);

LogDebug("Alma NCIP:Holdings response was[" .. APIResults .. "]");
	
local mms_id = APIResults:match("<mms_id>(.-)</mms_id");
local holding_id = APIResults:match("<holding_id>(.-)</holding_id>");
local pid = APIResults:match("<pid>(.-)</pid>");
local library = APIResults:match("<library desc=\"(.-)\"");
local location = APIResults:match("<location desc=\"(.-)\"");
local availability = APIResults:match("<base_status desc=\"(.-)\"");
-- if item is not in place then Alma lists a process type for that item
if (availability ~= "Item in place") then
	availability = APIResults:match("<process_type desc=\"(.-)\"");
end

local holdinglibrary = library .. " " .. location;

LogDebug('Alma NCIP:Found mms_id ' .. mms_id .. ', holding_id ' .. holding_id .. ', pid ' .. pid .. ' for barcode ' .. itembarcode .. " at " .. holdinglibrary .. ". Status: " .. availability);
return mms_id, holding_id, pid, holdinglibrary, availability;
end

function WandIn(barcode)
-- Wand-in at Resource Sharing Library after check-in (prevents erroneous "available" status)

-- call function to retrieve mms_id, holding_id, and pid from barcode via API

local tn = GetFieldValue("Transaction", "TransactionNumber");
local wandinbarcode = barcode;
local waitcounter = 0;
local availability = "";
local mmsid = "";
local holdingid = "";
local pid = "";
local holdinglibrary = "";

mmsid, holdingid, pid, holdinglibrary,availability = GetHoldingData(wandinbarcode);

if (availability == "Transit") then
	LogDebug("AlmaNCIP: Skipping wandin as item is in transit (likely as a result of pending Restore job)");
	ExecuteCommand("AddNote", {tn, "Skipping wandin as item is in transit (likely as a result of pending Restore job)"});
	return;
end

while (availability ~= "Item in place" and waitcounter < 10) do
	Sleep(2);
	waitcounter = waitcounter + 1;
	mmsid, holdingid, pid, holdinglibrary,availability = GetHoldingData(wandinbarcode);
end
			
local APIAddress = Settings.APIEndpoint .. 'bibs/' .. mmsid .. '/holdings/' .. holdingid .. '/items/' .. pid .. '?apikey=' .. Settings.APIKey .. '&user_id=' .. Settings.PseudopatronID .. '&op=SCAN&library=' ..  Settings.ResourceSharingLibraryCode .. '&circ_desk=' .. Settings.ResourceSharingCirculationDeskCode .. '&register_in_house_use=false&confirm=true';


LogDebug('AlmaNCIP:Attempting to use API endpoint ' .. APIAddress);
LogDebug('AlmaNCIP:API scan-in for barcode ' .. wandinbarcode);

luanet.load_assembly("System");
local APIWebClient = luanet.import_type("System.Net.WebClient");
local streamreader = luanet.import_type("System.Net.IO.StreamReader");
local ThisWebClient = APIWebClient();

ThisWebClient.Headers:Add("Content-Type","application/xml;charset=UTF-8");

local APIResults = "";

if pcall(function () APIResults = ThisWebClient:UploadString(APIAddress,''); end) then
	LogDebug("AlmaNCIP:WandIn response was[" .. APIResults .. "]");
	ExecuteCommand("AddNote", {tn, "API Scan-in for barcode ".. wandinbarcode .." performed at "..Settings.ResourceSharingLibraryCode ..":".. Settings.ResourceSharingCirculationDeskCode});
else
	LogDebug("AlmaNCIP:WandIn failed for barcode " .. wandinbarcode);
	ExecuteCommand("AddNote", {tn, "API Failure: Scan-in for barcode ".. wandinbarcode .." at "..Settings.ResourceSharingLibraryCode ..":".. Settings.ResourceSharingCirculationDeskCode .. " was not successful."});
end

end

-- Alma NCIP and API calls are prone to timing out.
function Sleep(s)
  local ntime = os.time() + s
  repeat until os.time() > ntime
end
	
	
--AcceptItem XML Builder for Borrowing
--sometimes Author fields and Title fields are blank
function buildAcceptItem(currentpiece,totalpieces)
local bibsuffix = "";
local tn = "";
local dr = tostring(GetFieldValue("Transaction", "DueDate"));
local df = string.match(dr, "%d+\/%d+\/%d+");
local mn, dy, yr = string.match(df, "(%d+)/(%d+)/(%d+)");
local mnt = string.format("%02d",mn);
local dya = string.format("%02d",dy);
local user = GetFieldValue("User", "SSN");
if Settings.Use_Prefixes then
	local t = GetFieldValue("Transaction", "TransactionNumber");
	if GetFieldValue("Transaction", "LibraryUseOnly") and GetFieldValue("Transaction", "RenewalsAllowed") then
	    tn = Settings.Prefix_for_LibraryUseOnly_and_RenewablesAllowed .. t;
	end
	if GetFieldValue("Transaction", "LibraryUseOnly") and GetFieldValue("Transaction", "RenewalsAllowed") ~= true then
	    tn = Settings.Prefix_for_LibraryUseOnly .. t;
	end
	if GetFieldValue("Transaction", "RenewalsAllowed") and GetFieldValue("Transaction", "LibraryUseOnly") ~= true then
		tn = Settings.Prefix_for_RenewablesAllowed .. t;
	end
	if GetFieldValue("Transaction", "LibraryUseOnly") ~= true and GetFieldValue("Transaction", "RenewalsAllowed") ~= true then
		tn = Settings.acceptItem_Transaction_Prefix .. t;
	end
else 
	tn = Settings.acceptItem_Transaction_Prefix .. GetFieldValue("Transaction", "TransactionNumber");
end

local author = GetFieldValue("Transaction", "LoanAuthor");
	if author == nil then
		author = "";
	end
	if string.find(author, "&") ~= nil then
		author = string.gsub(author, "&", "and");
	end
local title = GetFieldValue("Transaction", "LoanTitle");
	if title == nil then
		title = "";
	end
	if string.find(title, "&") ~= nil then
		title = string.gsub(title, "&", "and");
	end


if (GetFieldValue("Transaction", "LibraryUseOnly") == true) then
	bibsuffix = ' LIBRARY USE ONLY ';
end

if (GetFieldValue("Transaction", "RenewalsAllowed") ~= true) then
	bibsuffix = bibsuffix .. ' NO RENEWALS ';
end

if (bibsuffix ~= "") then
	bibsuffix = '[' .. bibsuffix .. '- due ' .. mnt .. '/' .. dya .. '/' .. yr .. ']';
	title = title .. bibsuffix;
end
	
local pickup_location_full = GetFieldValue("Transaction", "NVTGC");
local sublibraries = assert(io.open(AddonInfo.Directory .. "\\sublibraries.txt", "r"));
local pickup_location = "";
local comma_position = 1;
local templine = nil;
	if sublibraries ~= nil then
		for line in sublibraries:lines() do
			if string.find(line, pickup_location_full) ~= nil then
				comma_position = string.find(line,",");
				pickup_location = string.sub(line,comma_position + 1);
				break;
				
			else
				pickup_location = "nothing";
			end
		end
		sublibraries:close();
	end

local m = '';
    m = m .. '<?xml version="1.0" encoding="ISO-8859-1"?>'
	m = m .. '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">'
	m = m .. '<AcceptItem>'
	m = m .. '<InitiationHeader>'
	m = m .. '<FromAgencyId>'
	m = m .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	m = m .. '</FromAgencyId>'
	m = m .. '<ToAgencyId>'
	m = m .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	m = m .. '</ToAgencyId>'
	m = m .. '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType>'
	m = m .. '</InitiationHeader>'
	m = m .. '<RequestId>'
	m = m .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	m = m .. '<RequestIdentifierValue>' .. tn .. '</RequestIdentifierValue>'
	m = m .. '</RequestId>'
	m = m .. '<RequestedActionType>Hold For Pickup And Notify</RequestedActionType>'
	m = m .. '<UserId>'
	m = m .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	m = m .. '<UserIdentifierType>Barcode Id</UserIdentifierType>'
	m = m .. '<UserIdentifierValue>' .. user .. '</UserIdentifierValue>'
	m = m .. '</UserId>'
	m = m .. '<ItemId>'
	m = m .. '<ItemIdentifierValue>' .. tn .. '-' .. currentpiece .. 'OF' .. totalpieces .. '</ItemIdentifierValue>'
	m = m .. '</ItemId>'
	m = m .. '<DateForReturn>' .. yr .. '-' .. mnt .. '-' .. dya .. 'T23:59:00' .. '</DateForReturn>'
	m = m .. '<PickupLocation>' .. pickup_location .. '</PickupLocation>'
	m = m .. '<ItemOptionalFields>'
	m = m .. '<BibliographicDescription>'
	m = m .. '<Author>' .. author .. '</Author>'
	m = m .. '<Title>' .. title .. '</Title>'
	m = m .. '</BibliographicDescription>'
	m = m .. '</ItemOptionalFields>'
	m = m .. '</AcceptItem>'
	m = m .. '</NCIPMessage>'
	return m;
 end

--ReturnedItem XML Builder for Borrowing (Patron Returns)
function buildCheckInItemBorrowing(currentpiece,totalpieces)
local tn = "";
local user = GetFieldValue("User", "SSN");

if Settings.Use_Prefixes then
	local t = GetFieldValue("Transaction", "TransactionNumber");
	if GetFieldValue("Transaction", "LibraryUseOnly") and GetFieldValue("Transaction", "RenewalsAllowed") then
	    tn = Settings.Prefix_for_LibraryUseOnly_and_RenewablesAllowed .. t;
	end
	if GetFieldValue("Transaction", "LibraryUseOnly") and GetFieldValue("Transaction", "RenewalsAllowed") ~= true then
	    tn = Settings.Prefix_for_LibraryUseOnly .. t;
	end
	if GetFieldValue("Transaction", "RenewalsAllowed") and GetFieldValue("Transaction", "LibraryUseOnly") ~= true then
		tn = Settings.Prefix_for_RenewablesAllowed .. t;
	end
	if GetFieldValue("Transaction", "LibraryUseOnly") ~= true and GetFieldValue("Transaction", "RenewalsAllowed") ~= true then
		tn = Settings.acceptItem_Transaction_Prefix .. t;
	end
else 
	tn = Settings.acceptItem_Transaction_Prefix .. GetFieldValue("Transaction", "TransactionNumber");
end
	
local cib = '';
    cib = cib .. '<?xml version="1.0" encoding="ISO-8859-1"?>'
	cib = cib .. '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">'
	cib = cib .. '<CheckInItem>'
	cib = cib .. '<InitiationHeader>'
	cib = cib .. '<FromAgencyId>'
	cib = cib .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cib = cib .. '</FromAgencyId>'
	cib = cib .. '<ToAgencyId>'
	cib = cib .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cib = cib .. '</ToAgencyId>'
	cib = cib .. '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType>'
	cib = cib .. '</InitiationHeader>'
	cib = cib .. '<UserId>'
	cib = cib .. '<UserIdentifierValue>' .. user .. '</UserIdentifierValue>'
	cib = cib .. '</UserId>'
	cib = cib .. '<ItemId>'
	cib = cib .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cib = cib .. '<ItemIdentifierValue>' .. tn .. '-' .. currentpiece .. 'OF' .. totalpieces .. '</ItemIdentifierValue>'
	cib = cib .. '</ItemId>'
	cib = cib .. '<RequestId>'
	cib = cib .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cib = cib .. '<RequestIdentifierValue>' .. tn .. '</RequestIdentifierValue>'
	cib = cib .. '</RequestId>'
	cib = cib .. '</CheckInItem>'
	cib = cib .. '</NCIPMessage>'
	return cib;
end

--ReturnedItem XML Builder for Lending (Library Returns)
function buildCheckInItemLending(barcode)
local ttype = "";
local user = GetFieldValue("Transaction", "Username");
local itembarcode = barcode;
local tn = GetFieldValue("Transaction", "TransactionNumber");
	
local cil = '';
    cil = cil .. '<?xml version="1.0" encoding="ISO-8859-1"?>'
	cil = cil .. '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">'
	cil = cil .. '<CheckInItem>'
	cil = cil .. '<InitiationHeader>'
	cil = cil .. '<FromAgencyId>'
	cil = cil .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cil = cil .. '</FromAgencyId>'
	cil = cil .. '<ToAgencyId>'
	cil = cil .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cil = cil .. '</ToAgencyId>'
	cil = cil .. '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType>'
	cil = cil .. '</InitiationHeader>'
	cil = cil .. '<UserId>'
	cil = cil .. '<UserIdentifierValue>' .. user .. '</UserIdentifierValue>'
	cil = cil .. '</UserId>'
	cil = cil .. '<ItemId>'
	cil = cil .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cil = cil .. '<ItemIdentifierValue>' .. itembarcode .. '</ItemIdentifierValue>'
	cil = cil .. '</ItemId>'
	cil = cil .. '<RequestId>'
	cil = cil .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cil = cil .. '<RequestIdentifierValue>' .. tn .. '</RequestIdentifierValue>'
	cil = cil .. '</RequestId>'
	cil = cil .. '</CheckInItem>'
	cil = cil .. '</NCIPMessage>'
	return cil;
end

--CheckOutItem XML Builder for Lending
function buildCheckOutItem(barcode)
local dr = tostring(GetFieldValue("Transaction", "DueDate"));
local df = string.match(dr, "%d+\/%d+\/%d+");
local mn, dy, yr = string.match(df, "(%d+)/(%d+)/(%d+)");
local mnt = string.format("%02d",mn);
local dya = string.format("%02d",dy);
local pseudopatron = 'pseudopatron';
local itembarcode = barcode;
local tn = Settings.checkOutItem_RequestIdentifierValue_Prefix .. GetFieldValue("Transaction", "TransactionNumber");
local coi = '';
    --coi = coi .. '<?xml version="1.0" encoding="ISO-8859-1"?>'
	coi = coi .. '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">'
	coi = coi .. '<CheckOutItem>'
	coi = coi .. '<InitiationHeader>'
	coi = coi .. '<FromAgencyId>' 
	coi = coi .. '<AgencyId>' .. Settings.ILLiad_NCIP_Agency_value .. '</AgencyId>'
	coi = coi .. '</FromAgencyId>'
	coi = coi .. '<ToAgencyId>' 
	coi = coi .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	coi = coi .. '</ToAgencyId>'
	coi = coi .. '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType>'
	coi = coi .. '</InitiationHeader>'
	coi = coi .. '<UserId>'
	coi = coi .. '<UserIdentifierValue>' .. pseudopatron .. '</UserIdentifierValue>'
	coi = coi .. '</UserId>'
	coi = coi .. '<ItemId>'
	coi = coi .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	coi = coi .. '<ItemIdentifierValue>' .. itembarcode .. '</ItemIdentifierValue>'
	coi = coi .. '</ItemId>'
	coi = coi .. '<RequestId>'
	coi = coi .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	coi = coi .. '<RequestIdentifierValue>' .. tn .. '</RequestIdentifierValue>'
	coi = coi .. '</RequestId>'
	coi = coi .. '</CheckOutItem>'
	coi = coi .. '</NCIPMessage>'
	return coi;
	
end

--A simple function to get the number of pieces in a transaction for iterative actions
function CountPieces()
local pieces = GetFieldValue("Transaction","Pieces");
if ((pieces == '' ) or (pieces == nil)) then
	pieces = 0;
	end
return pieces;
end

-- A simple function that takes delimited string and returns an array of delimited values
function Parse(inputstr, delim)
if (inputstr == "") then return "";
else
delim = delim or '/';
local result = {};
local match = '';

for match in (inputstr..delim):gmatch("(.-)"..delim) do
	table.insert(result,match);
end
	return result;
end

end

--ReturnedItem XML Builder for Legacy Borrowing (Patron Returns)
--Allows failed NCIP checkins to be retried using barcode specified by legacy IDS addons
function buildLegacyCheckInItemBorrowing(currentTN)
local user = GetFieldValue("User", "SSN");
	
local cib = '';
    cib = cib .. '<?xml version="1.0" encoding="ISO-8859-1"?>'
	cib = cib .. '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">'
	cib = cib .. '<CheckInItem>'
	cib = cib .. '<InitiationHeader>'
	cib = cib .. '<FromAgencyId>'
	cib = cib .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cib = cib .. '</FromAgencyId>'
	cib = cib .. '<ToAgencyId>'
	cib = cib .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cib = cib .. '</ToAgencyId>'
	cib = cib .. '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType>'
	cib = cib .. '</InitiationHeader>'
	cib = cib .. '<UserId>'
	cib = cib .. '<UserIdentifierValue>' .. user .. '</UserIdentifierValue>'
	cib = cib .. '</UserId>'
	cib = cib .. '<ItemId>'
	cib = cib .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cib = cib .. '<ItemIdentifierValue>' .. currentTN .. '</ItemIdentifierValue>'
	cib = cib .. '</ItemId>'
	cib = cib .. '<RequestId>'
	cib = cib .. '<AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId>'
	cib = cib .. '<RequestIdentifierValue>' .. currentTN .. '</RequestIdentifierValue>'
	cib = cib .. '</RequestId>'
	cib = cib .. '</CheckInItem>'
	cib = cib .. '</NCIPMessage>'
	return cib;
end