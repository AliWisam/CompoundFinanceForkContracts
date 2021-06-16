pragma solidity ^0.5.16;

import "./ComptrollerInterface.sol";

contract BAIUnitrollerAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of Unitroller
    */
    address public baiControllerImplementation;

    /**
    * @notice Pending brains of Unitroller
    */
    address public pendingBAIControllerImplementation;
}

contract BAIControllerStorageG1 is BAIUnitrollerAdminStorage {
    ComptrollerInterface public comptroller;

    struct BtntexBAIState {
        /// @notice The last updated btntexBAIMintIndex
        uint224 index;

        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice The Btntex BAI state
    BtntexBAIState public btntexBAIState;

    /// @notice The Btntex BAI state initialized
    bool public isBtntexBAIInitialized;

    /// @notice The Btntex BAI minter index as of the last time they accrued BTNT
    mapping(address => uint) public btntexBAIMinterIndex;
}

contract BAIControllerStorageG2 is BAIControllerStorageG1 {
    /// @notice Treasury Guardian address
    address public treasuryGuardian;

    /// @notice Treasury address
    address public treasuryAddress;

    /// @notice Fee percent of accrued interest with decimal 18
    uint256 public treasuryPercent;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;
}
