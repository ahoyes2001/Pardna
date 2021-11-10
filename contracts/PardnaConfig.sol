//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "../client/node_modules/@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PardnaConfig {

    // ARRAYS
    User[] public users;
    Pardna[] public pardnas;

    // MAPPINGS
    mapping (address => uint256[]) public pardnasParticipatingIn;
    mapping (address => User) public addressToUser;
    mapping (uint256 => Pardna) public codeToPardna;
    mapping (address =>  mapping (uint256 => User)) addressToMember;
    

    // EVENTS
    event newPardnaCreated (string _name, uint256 _expectedDraw);

    //MODIFIERS *** TODO: Throw events react can interpret;
    modifier onlyUsers {require(addressToUser[msg.sender].isActive,"Log in to access this function");_;} 

    modifier onlyMembers (uint256 _inviteCode) {
        bool _isMember = false;
        for(uint i=0;
            i<=pardnasParticipatingIn[msg.sender].length-1;
            i++){
                if (pardnasParticipatingIn[msg.sender][i] == _inviteCode){
                    _isMember = true;
                }
            }
                require(_isMember,"Join this pardna to access this function");
            _;} 

    modifier onlyBanker (uint256 _inviteCode)
    {require(codeToPardna[_inviteCode].banker.wallet == msg.sender,"Only the banker of thie Pardna can access this function");_;} 

    modifier onlyNewUsers {
        require(!addressToUser[msg.sender].isActive,"User already exists");
     // require(addressToUser[msg.sender].username !=_username,"That username is taken");
        _;
    }

    // STATE VARIABLES
    uint256 idNonce = 0;

    // ENUMS
    enum votableVals{
        inviteOnly,
        maxMembers,
        earlyDrawThreshold

    }


    struct User{
        bool isActive;
        address payable wallet;
        string username;
        uint256 value; // Total funds User has in Pardnas
    }

    struct Pardna{

        uint256 id;
        bool isActive;
        string name;
        User banker; /* Default: caller of createNewPardna, but can be another user set by the caller. Responsible for setting values marked with #SETTABLE. 
                        Does not have any control over the funds stored in a Pardna */
        bool inviteOnly; // #SETTABLE
        uint inviteCode;
        User[] members;

        uint256 totalPurse; // Total holdings of a specific Pardna, plays a determining role in earlyDrawThreshold
        uint256 expectedDraw; // Expected amount each member is projected draw at the end of the duration. 
        uint256 duration; // How long Pardna will run for
        uint256 maxMembers; // #SETTABLE
        uint256 totalMembers; // members.length
        uint256 openSlots; // maxMembers-totalMembers

        uint256 throwFrequency; 
        uint256 throwAmount; // Set $$$ per throw
        uint256 numThrows; // Number of throws that have passed 
        uint256 totalThrows; // throwDates.length
        uint256 remainingThrows; // totalThrows - numThrows
        uint256[] throwDates; // An array of throw dates based on duration and frequency
        uint256 firstThrowDate;
        uint256 finalThrowDate;
        uint256 drawDate;

        bool earlyDrawEnabled; // Determines if a member can take their draw before making all their throws, must be voted on by other members #SETTABLE #VOTE
        uint256 earlyDrawThreshold; // The earliest date that an early draw can be made 

        
        bool lateJoinEnabled; // Determines if a new member may join after the throws have already begun 
        uint256 lateJoinThreshold; // The most draws that could have passed and a new member registration is accepted. 
        
    }

}

contract PardnaMutations is PardnaConfig, ReentrancyGuard {

    function createNewPardna(
        string memory _name,
        bool _inviteOnly,
        uint256 _duration,
        uint256 _maxMembers,
        uint256 _firstThrowDate,
        uint256 _throwFrequency,
        uint256 _throwAmount,
        bool _earlyDrawEnabled,
        bool _lateJoinEnabled,
        uint256 _lateJoinThreshold
    ) public onlyUsers{

        Pardna memory _pardna; // Update to dynamic id
        User storage _caller = addressToUser[msg.sender];

        //Stop dApp-breaking or memory intensive value combinations
        require(_duration > _throwFrequency*2,"Pardna must have at least 2 throws");
        require(_throwFrequency <= 52, "Pardna cannot have more than 52 throws");
        require(_duration <= 365 days, "Pardna cannot last over a year"); 
        require(_maxMembers >=2 && _maxMembers <= 500,"Pardna must have 2 - 500 members");
        require(_throwAmount <= 10 ether, "Throw amount cannot exceed 10 ether"); //TODO: JMD-Pegged Token

        // Identifying attributes
        _pardna.id = idNonce++;
        _pardna.inviteCode = uint(keccak256(abi.encodePacked(idNonce))) % (10**6); //TODO: Make slightly less predictable
        

        // Setting #SETTABLE attributes
        _pardna.name = _name;
        _pardna.inviteOnly = _inviteOnly;
        _pardna.duration = _duration;
        _pardna.maxMembers = _maxMembers;
        _pardna.throwFrequency = _throwFrequency;
        _pardna.throwAmount = _throwAmount;
        _pardna.earlyDrawEnabled = _earlyDrawEnabled;
        _pardna.lateJoinEnabled = _lateJoinEnabled;
        _pardna.inviteOnly = _inviteOnly;
        _pardna.finalThrowDate = _firstThrowDate;

        createNewPardna2(_pardna,_duration, _lateJoinThreshold, _caller, _name);
    }

    // Split into two functions to escape "CompilerError: Stack too deep, try removing local variables."

    function createNewPardna2(Pardna memory _pardna,uint256 _duration, uint256 _lateJoinThreshold, User memory _caller, string memory _name) private{

        // Initializing automatic attributes
        _pardna.isActive = true;
        _pardna.banker = _caller; // TODO: Update to allow custom banker at init
        _pardna.totalPurse = 0;
        _pardna.numThrows = 0;

       // Initializing calculated attributes
       _pardna.totalMembers = _pardna.members.length;
       _pardna.openSlots = _pardna.totalMembers - _pardna.maxMembers;
       _pardna.totalThrows = _pardna.throwDates.length;
       _pardna.remainingThrows = _pardna.totalThrows - _pardna.numThrows;
       _pardna.expectedDraw = _pardna.throwAmount * _pardna.totalThrows;
       _pardna.earlyDrawThreshold = _pardna.expectedDraw * 2; 
       _pardna.drawDate = _pardna.firstThrowDate + _duration;
       _pardna.finalThrowDate = _pardna.drawDate - (_pardna.drawDate % _pardna.throwFrequency);

       createNewPardna3(_pardna, _lateJoinThreshold, _caller, _name);
       
    }

    function createNewPardna3(Pardna memory _pardna, uint256 _lateJoinThreshold, User memory _caller, string memory _name) private {
       //Setting throwDates
       uint256 _tDi = 0;
       for(uint curr = _pardna.firstThrowDate;curr <= _pardna.finalThrowDate;curr += _pardna.throwFrequency){
           
             _pardna.throwDates[_tDi] = curr;
       }

        //Publishing Pardna to directory
       require(_lateJoinThreshold < _pardna.numThrows/2); //Ensure someone cannot join more than halfway through
       pardnas.push(_pardna);
       codeToPardna[_pardna.inviteCode] = pardnas[pardnas.length-1]; //make inviteCode searchable
       pardnas[pardnas.length-1].members.push(_caller); //set msg.sender as the first member
       emit newPardnaCreated(_name,_pardna.expectedDraw);
    }


    function joinPardna (uint256 _inviteCode) 
    public payable onlyUsers {

            // Ensuring the user can logically join the pardna
            require(codeToPardna[_inviteCode].isActive,"Invalid invite code");
            require(codeToPardna[_inviteCode].openSlots > 0, "This pardna is full");
            for (uint i=0;i<=codeToPardna[_inviteCode].members.length; i++)
            {
                require(payable(msg.sender) != codeToPardna[_inviteCode].members[i].wallet);
            }

            if(codeToPardna[_inviteCode].lateJoinEnabled){
                require (codeToPardna[_inviteCode].numThrows < codeToPardna[_inviteCode].lateJoinThreshold,"It is too late to join this Pardna");
                require(msg.value == codeToPardna[_inviteCode].throwAmount * codeToPardna[_inviteCode].numThrows); // Ensures the user is caught up on throw payments if registering late
            } else {
                require (block.timestamp > codeToPardna[_inviteCode].throwDates[1] ,"It is too late to join this Pardna"); // If no late registration, ensures the user joins before ths second throw date
                if (block.timestamp < codeToPardna[_inviteCode].firstThrowDate){require (msg.value == codeToPardna[_inviteCode].throwAmount);} // If user joins after first throw (technically not late), ensures they throw up front
            }

            
            codeToPardna[_inviteCode].members.push(addressToUser[msg.sender]); // Adds the user to the Pardna member list
            addressToMember[msg.sender][_inviteCode] = codeToPardna[_inviteCode].members[codeToPardna[_inviteCode].members.length-1];
            addressToMember[msg.sender][_inviteCode].value = msg.value;

            throwToPardna(_inviteCode);
            pardnasParticipatingIn[msg.sender].push(_inviteCode); // Adds Pardna to the list of Pardnas the user is participating in


    }

    function throwToPardna (uint256 _inviteCode)
    internal { 
        codeToPardna[_inviteCode].totalPurse += msg.value;
        addressToMember[msg.sender][_inviteCode].value += msg.value;
    }


    function killAll(uint256 _inviteCode) internal nonReentrant {
        for(uint i=0;i<=codeToPardna[_inviteCode].members.length;i++){
            (bool sent, bytes memory data) = codeToPardna[_inviteCode].members[i].wallet.call{value: addressToMember[msg.sender][_inviteCode].value}("");
            addressToMember[msg.sender][_inviteCode].value = 0;
            require(sent, "Failed to refund"); 
            data;  
        }
        codeToPardna[_inviteCode].totalPurse = 0;
        codeToPardna[_inviteCode].isActive = false;
    }

      function deactivatePardna (uint256 _inviteCode) 
    public onlyBanker(_inviteCode){
    /*Refunds all members their total holding within
    the Pardna then changes its isActive to false */
        killAll(_inviteCode);
    }

    }

  


contract PardnaQueries is PardnaMutations{
        // ARRAYS
        Pardna[] public publicPardnas;

        function pardnaDirectory() public returns (Pardna[] memory){
        // Lists all public Pardnas with open slots 
            for(uint i=0;i<=pardnas.length;i++){
                    if (!pardnas[i].inviteOnly && pardnas[i].openSlots > 0 && block.timestamp > pardnas[i].throwDates[1]){
                        publicPardnas.push(pardnas[i]);
                    }
            }

        return publicPardnas;

        }

        function viewMembers(uint256 _inviteCode)
        public view onlyMembers(_inviteCode)
        returns(User[] memory){
           // Lists all the members of a Pardna, only viewable by other members 
           return codeToPardna[_inviteCode].members;
        }

        function importantInfo(uint256 _inviteCode)
        public view returns(string memory,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256) {
            Pardna memory _pardna = codeToPardna[_inviteCode];
            return(
                _pardna.name,
                _pardna.inviteCode,
                _pardna.duration,
                _pardna.throwFrequency,
                _pardna.throwAmount,
                _pardna.firstThrowDate,
                _pardna.expectedDraw,
                _pardna.openSlots,
                _pardna.maxMembers
                );

        }

}

contract UserMutations is PardnaMutations {

    function createUser(string memory _username)
    public onlyNewUsers{
        require(tx.origin==msg.sender,"Only humans are allowed to join Pardna ;)");
        users.push(User(true, payable(msg.sender), _username,0));
        require(users[users.length-1].wallet==payable(msg.sender),"Account was not created. Please try again.");
    }

    function deactivateUser() public {addressToUser[msg.sender].isActive = false;}
}

contract UserQueries is UserMutations {

    function myPardnas() public view onlyUsers returns(string[] memory) {
        require(pardnasParticipatingIn[msg.sender].length>0,"You are not a member of any Pardnas");
        string[] memory _myPardnas;
        for (uint i=0; i<=pardnasParticipatingIn[msg.sender].length; i++){
                _myPardnas[i] = codeToPardna[pardnasParticipatingIn[msg.sender][i]].name;
        }
        return _myPardnas;
    } 

}

contract Teller is PardnaMutations{

    event earlyDrawRequested(User, uint256 _time, uint256 _amount);
    mapping (address => mapping(address => mapping(uint256 => bool))) earlyDrawVote;
    mapping (address => mapping(uint256 => bool)) earlyDrawRequest;

    function makeThrow(uint256 _inviteCode) public payable onlyMembers(_inviteCode){
        require(codeToPardna[_inviteCode].isActive);
        require(msg.value == codeToPardna[_inviteCode].throwAmount,"Ensure you are throwing the correct amount");
        require(addressToMember[msg.sender][_inviteCode].value < codeToPardna[_inviteCode].throwAmount * codeToPardna[_inviteCode].numThrows,"You don't have any throws due");
        throwToPardna(_inviteCode);
    }

    function payoutDraw(uint256 _inviteCode) public onlyMembers(_inviteCode) nonReentrant {
        require(block.timestamp > codeToPardna[_inviteCode].finalThrowDate);
        require(addressToMember[msg.sender][_inviteCode].value == codeToPardna[_inviteCode].throwAmount * codeToPardna[_inviteCode].numThrows);
        (bool sent, bytes memory data) = msg.sender.call{value: addressToMember[msg.sender][_inviteCode].value}("");
        require(sent);
        data;
        addressToMember[msg.sender][_inviteCode].value = 0;
    }

    function requestEarlyDraw(uint256 _inviteCode) public onlyMembers(_inviteCode){
        require(codeToPardna[_inviteCode].earlyDrawEnabled);
        earlyDrawRequest[msg.sender][_inviteCode] = true;
        emit earlyDrawRequested(addressToMember[msg.sender][_inviteCode], block.timestamp, codeToPardna[_inviteCode].expectedDraw);
    }

    function approveEarlyDraw(uint256 _inviteCode, address _requester)
    public onlyMembers(_inviteCode){
        require(codeToPardna[_inviteCode].earlyDrawEnabled);
        require(earlyDrawRequest[_requester][_inviteCode]);
        earlyDrawVote[msg.sender][_requester][_inviteCode] = true;

        uint256 votes;

        for (uint i=0;i<=codeToPardna[_inviteCode].members.length;i++){
                if (earlyDrawVote[codeToPardna[_inviteCode].members[i].wallet][_requester][_inviteCode]){
                    votes++;
                }
        }

        if(votes>codeToPardna[_inviteCode].members.length){
            _requester.call{value:codeToPardna[_inviteCode].expectedDraw};
        }

    }

    function throwTracker(uint256 _inviteCode) public nonReentrant{ //ONLY PUBLIC FOR TESTING, WILL BE CALLED BY ORACLE
    /* This function is meant to be run every
    codeToPardna[_inviteCode].throwFrequency
    starting at firstThrowDate. TODO: Oraclize
    or Ethereum Alarm Clock*/



    codeToPardna[_inviteCode].numThrows++; //Inctreases numThrows every throw period



        // Refunds and deactivates dormant members (missed 3 or more throws)
        for (uint i=0;i<=codeToPardna[_inviteCode].members.length;i++){
            if (codeToPardna[_inviteCode].numThrows >= 3 && 
                addressToMember[codeToPardna[_inviteCode].members[i].wallet][_inviteCode].value <= (codeToPardna[_inviteCode].numThrows - 3) * codeToPardna[_inviteCode].throwAmount)
                {
                    codeToPardna[_inviteCode].members[i].isActive = false;
                    (bool sent, bytes memory data) = codeToPardna[_inviteCode].members[i].wallet.call{value: addressToMember[codeToPardna[_inviteCode].members[i].wallet][_inviteCode].value}("");
                    require(sent);
                    data;
                    addressToMember[codeToPardna[_inviteCode].members[i].wallet][_inviteCode].value = 0;

                }
        }

    }



}