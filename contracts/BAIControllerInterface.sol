pragma solidity ^0.5.16;

contract BAIControllerInterface {
    function getBAIAddress() public view returns (address);
    function getMintableBAI(address minter) public view returns (uint, uint);
    function mintBAI(address minter, uint mintBAIAmount) external returns (uint);
    function repayBAI(address repayer, uint repayBAIAmount) external returns (uint);

    function _initializeBtntexBAIState(uint blockNumber) external returns (uint);
    function updateBtntexBAIMintIndex() external returns (uint);
    function calcDistributeBAIMinterBtntex(address baiMinter) external returns(uint, uint, uint, uint);
}
