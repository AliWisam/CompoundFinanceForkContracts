pragma solidity ^0.5.16;
import "./SafeBEP20.sol";
import "./IBEP20.sol";
import "./BAIVaultProxy.sol";
import "./BAIVaultStorage.sol";
import "./BAIVaultErrorReporter.sol";

contract BAIVault is BAIVaultStorage {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /// @notice Event emitted when BAI deposit
    event Deposit(address indexed user, uint256 amount);

    /// @notice Event emitted when BAI withrawal
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Event emitted when admin changed
    event AdminTransfered(address indexed oldAdmin, address indexed newAdmin);

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    /**
     * @notice Deposit BAI to BAIVault for BTNT allocation
     * @param _amount The amount to deposit to vault
     */
    function deposit(uint256 _amount) public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        updateVault();

        // Transfer pending tokens to user
        updateAndPayOutPending(msg.sender);

        // Transfer in the amounts from user
        if(_amount > 0) {
            bai.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }

        user.rewardDebt = user.amount.mul(accBTNTPerShare).div(1e18);
        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice Withdraw BAI from BAIVault
     * @param _amount The amount to withdraw from vault
     */
    function withdraw(uint256 _amount) public nonReentrant {
        _withdraw(msg.sender, _amount);
    }

    /**
     * @notice Claim BTNT from BAIVault
     */
    function claim() public nonReentrant {
        _withdraw(msg.sender, 0);
    }

    /**
     * @notice Low level withdraw function
     * @param account The account to withdraw from vault
     * @param _amount The amount to withdraw from vault
     */
    function _withdraw(address account, uint256 _amount) internal {
        UserInfo storage user = userInfo[account];
        require(user.amount >= _amount, "withdraw: not good");

        updateVault();
        updateAndPayOutPending(account); // Update balances of account this is not withdrawal but claiming BTNT farmed

        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            bai.safeTransfer(address(account), _amount);
        }
        user.rewardDebt = user.amount.mul(accBTNTPerShare).div(1e18);

        emit Withdraw(account, _amount);
    }

    /**
     * @notice View function to see pending BTNT on frontend
     * @param _user The user to see pending BTNT
     */
    function pendingBTNT(address _user) public view returns (uint256)
    {
        UserInfo storage user = userInfo[_user];

        return user.amount.mul(accBTNTPerShare).div(1e18).sub(user.rewardDebt);
    }

    /**
     * @notice Update and pay out pending BTNT to user
     * @param account The user to pay out
     */
    function updateAndPayOutPending(address account) internal {
        uint256 pending = pendingBTNT(account);

        if(pending > 0) {
            safeBTNTTransfer(account, pending);
        }
    }

    /**
     * @notice Safe BTNT transfer function, just in case if rounding error causes pool to not have enough BTNT
     * @param _to The address that BTNT to be transfered
     * @param _amount The amount that BTNT to be transfered
     */
    function safeBTNTTransfer(address _to, uint256 _amount) internal {
        uint256 btntBal = btnt.balanceOf(address(this));

        if (_amount > btntBal) {
            btnt.transfer(_to, btntBal);
            btntBalance = btnt.balanceOf(address(this));
        } else {
            btnt.transfer(_to, _amount);
            btntBalance = btnt.balanceOf(address(this));
        }
    }

    /**
     * @notice Function that updates pending rewards
     */
    function updatePendingRewards() public {
        uint256 newRewards = btnt.balanceOf(address(this)).sub(btntBalance);

        if(newRewards > 0) {
            btntBalance = btnt.balanceOf(address(this)); // If there is no change the balance didn't change
            pendingRewards = pendingRewards.add(newRewards);
        }
    }

    /**
     * @notice Update reward variables to be up-to-date
     */
    function updateVault() internal {
        uint256 baiBalance = bai.balanceOf(address(this));
        if (baiBalance == 0) { // avoids division by 0 errors
            return;
        }

        accBTNTPerShare = accBTNTPerShare.add(pendingRewards.mul(1e18).div(baiBalance));
        pendingRewards = 0;
    }

    /**
     * @dev Returns the address of the current admin
     */
    function getAdmin() public view returns (address) {
        return admin;
    }

    /**
     * @dev Burn the current admin
     */
    function burnAdmin() public onlyAdmin {
        emit AdminTransfered(admin, address(0));
        admin = address(0);
    }

    /**
     * @dev Set the current admin to new address
     */
    function setNewAdmin(address newAdmin) public onlyAdmin {
        require(newAdmin != address(0), "new owner is the zero address");
        emit AdminTransfered(admin, newAdmin);
        admin = newAdmin;
    }

    /*** Admin Functions ***/

    function _become(BAIVaultProxy baiVaultProxy) public {
        require(msg.sender == baiVaultProxy.admin(), "only proxy admin can change brains");
        require(baiVaultProxy._acceptImplementation() == 0, "change not authorized");
    }

    function setBtntexInfo(address _btnt, address _bai) public onlyAdmin {
        btnt = IBEP20(_btnt);
        bai = IBEP20(_bai);

        _notEntered = true;
    }
}
