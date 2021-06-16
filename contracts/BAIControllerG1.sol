pragma solidity ^0.5.16;

import "./BToken.sol";
import "./PriceOracle.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./BAIControllerStorage.sol";
import "./BAIUnitroller.sol";
import "./BAI.sol";

interface ComptrollerLensInterface {
    function protocolPaused() external view returns (bool);
    function mintedBAIs(address account) external view returns (uint);
    function baiMintRate() external view returns (uint);
    function btntexBAIRate() external view returns (uint);
    function btntexAccrued(address account) external view returns(uint);
    function getAssetsIn(address account) external view returns (BToken[] memory);
    function oracle() external view returns (PriceOracle);

    function distributeBAIMinterBtntex(address baiMinter, bool distributeAll) external;
}

/**
 * @title Btntex's BAI Comptroller Contract
 * @author Btntex
 */
contract BAIControllerG1 is BAIControllerStorageG1, BAIControllerErrorReporter, Exponential {

    /// @notice Emitted when Comptroller is changed
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);

    /**
     * @notice Event emitted when BAI is minted
     */
    event MintBAI(address minter, uint mintBAIAmount);

    /**
     * @notice Event emitted when BAI is repaid
     */
    event RepayBAI(address repayer, uint repayBAIAmount);

    /// @notice The initial Btntex index for a market
    uint224 public constant btntexInitialIndex = 1e36;

    /*** Main Actions ***/

    function mintBAI(uint mintBAIAmount) external returns (uint) {
        if(address(comptroller) != address(0)) {
            require(!ComptrollerLensInterface(address(comptroller)).protocolPaused(), "protocol is paused");

            address minter = msg.sender;

            // Keep the flywheel moving
            updateBtntexBAIMintIndex();
            ComptrollerLensInterface(address(comptroller)).distributeBAIMinterBtntex(minter, false);

            uint oErr;
            MathError mErr;
            uint accountMintBAINew;
            uint accountMintableBAI;

            (oErr, accountMintableBAI) = getMintableBAI(minter);
            if (oErr != uint(Error.NO_ERROR)) {
                return uint(Error.REJECTION);
            }

            // check that user have sufficient mintableBAI balance
            if (mintBAIAmount > accountMintableBAI) {
                return fail(Error.REJECTION, FailureInfo.BAI_MINT_REJECTION);
            }

            (mErr, accountMintBAINew) = addUInt(ComptrollerLensInterface(address(comptroller)).mintedBAIs(minter), mintBAIAmount);
            require(mErr == MathError.NO_ERROR, "BAI_MINT_AMOUNT_CALCULATION_FAILED");
            uint error = comptroller.setMintedBAIOf(minter, accountMintBAINew);
            if (error != 0 ) {
                return error;
            }

            BAI(getBAIAddress()).mint(minter, mintBAIAmount);
            emit MintBAI(minter, mintBAIAmount);

            return uint(Error.NO_ERROR);
        }
    }

    /**
     * @notice Repay BAI
     */
    function repayBAI(uint repayBAIAmount) external returns (uint) {
        if(address(comptroller) != address(0)) {
            require(!ComptrollerLensInterface(address(comptroller)).protocolPaused(), "protocol is paused");

            address repayer = msg.sender;

            updateBtntexBAIMintIndex();
            ComptrollerLensInterface(address(comptroller)).distributeBAIMinterBtntex(repayer, false);

            uint actualBurnAmount;

            uint baiBalance = ComptrollerLensInterface(address(comptroller)).mintedBAIs(repayer);

            if(baiBalance > repayBAIAmount) {
                actualBurnAmount = repayBAIAmount;
            } else {
                actualBurnAmount = baiBalance;
            }

            uint error = comptroller.setMintedBAIOf(repayer, baiBalance - actualBurnAmount);
            if (error != 0) {
                return error;
            }

            BAI(getBAIAddress()).burn(repayer, actualBurnAmount);
            emit RepayBAI(repayer, actualBurnAmount);

            return uint(Error.NO_ERROR);
        }
    }

    /**
     * @notice Initialize the BtntexBAIState
     */
    function _initializeBtntexBAIState(uint blockNumber) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        if (isBtntexBAIInitialized == false) {
            isBtntexBAIInitialized = true;
            uint baiBlockNumber = blockNumber == 0 ? getBlockNumber() : blockNumber;
            btntexBAIState = BtntexBAIState({
                index: btntexInitialIndex,
                block: safe32(baiBlockNumber, "block number overflows")
            });
        }
    }

    /**
     * @notice Accrue BTNT to by updating the BAI minter index
     */
    function updateBtntexBAIMintIndex() public returns (uint) {
        uint baiMinterSpeed = ComptrollerLensInterface(address(comptroller)).btntexBAIRate();
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(btntexBAIState.block));
        if (deltaBlocks > 0 && baiMinterSpeed > 0) {
            uint baiAmount = BAI(getBAIAddress()).totalSupply();
            uint btntexAccrued = mul_(deltaBlocks, baiMinterSpeed);
            Double memory ratio = baiAmount > 0 ? fraction(btntexAccrued, baiAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: btntexBAIState.index}), ratio);
            btntexBAIState = BtntexBAIState({
                index: safe224(index.mantissa, "new index overflows"),
                block: safe32(blockNumber, "block number overflows")
            });
        } else if (deltaBlocks > 0) {
            btntexBAIState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @notice Calculate BTNT accrued by a BAI minter
     * @param baiMinter The address of the BAI minter to distribute BTNT to
     */
    function calcDistributeBAIMinterBtntex(address baiMinter) public returns(uint, uint, uint, uint) {
        // Check caller is comptroller
        if (msg.sender != address(comptroller)) {
            return (fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK), 0, 0, 0);
        }

        Double memory baiMintIndex = Double({mantissa: btntexBAIState.index});
        Double memory baiMinterIndex = Double({mantissa: btntexBAIMinterIndex[baiMinter]});
        btntexBAIMinterIndex[baiMinter] = baiMintIndex.mantissa;

        if (baiMinterIndex.mantissa == 0 && baiMintIndex.mantissa > 0) {
            baiMinterIndex.mantissa = btntexInitialIndex;
        }

        Double memory deltaIndex = sub_(baiMintIndex, baiMinterIndex);
        uint baiMinterAmount = ComptrollerLensInterface(address(comptroller)).mintedBAIs(baiMinter);
        uint baiMinterDelta = mul_(baiMinterAmount, deltaIndex);
        uint baiMinterAccrued = add_(ComptrollerLensInterface(address(comptroller)).btntexAccrued(baiMinter), baiMinterDelta);
        return (uint(Error.NO_ERROR), baiMinterAccrued, baiMinterDelta, baiMintIndex.mantissa);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new comptroller
      * @dev Admin function to set a new comptroller
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setComptroller(ComptrollerInterface comptroller_) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        ComptrollerInterface oldComptroller = comptroller;
        comptroller = comptroller_;
        emit NewComptroller(oldComptroller, comptroller_);

        return uint(Error.NO_ERROR);
    }

    function _become(BAIUnitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account total supply balance.
     *  Note that `bTokenBalance` is the number of bTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountAmountLocalVars {
        uint totalSupplyAmount;
        uint sumSupply;
        uint sumBorrowPlusEffects;
        uint bTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    function getMintableBAI(address minter) public view returns (uint, uint) {
        PriceOracle oracle = ComptrollerLensInterface(address(comptroller)).oracle();
        BToken[] memory enteredMarkets = ComptrollerLensInterface(address(comptroller)).getAssetsIn(minter);

        AccountAmountLocalVars memory vars; // Holds all our calculation results

        uint oErr;
        MathError mErr;

        uint accountMintableBAI;
        uint i;

        /**
         * We use this formula to calculate mintable BAI amount.
         * totalSupplyAmount * BAIMintRate - (totalBorrowAmount + mintedBAIOf)
         */
        for (i = 0; i < enteredMarkets.length; i++) {
            (oErr, vars.bTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = enteredMarkets[i].getAccountSnapshot(minter);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (uint(Error.SNAPSHOT_ERROR), 0);
            }
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(enteredMarkets[i]);
            if (vars.oraclePriceMantissa == 0) {
                return (uint(Error.PRICE_ERROR), 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            (mErr, vars.tokensToDenom) = mulExp(vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // sumSupply += tokensToDenom * bTokenBalance
            (mErr, vars.sumSupply) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.bTokenBalance, vars.sumSupply);
            if (mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            if (mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }
        }

        (mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, ComptrollerLensInterface(address(comptroller)).mintedBAIs(minter));
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mErr, accountMintableBAI) = mulUInt(vars.sumSupply, ComptrollerLensInterface(address(comptroller)).baiMintRate());
        require(mErr == MathError.NO_ERROR, "BAI_MINT_AMOUNT_CALCULATION_FAILED");

        (mErr, accountMintableBAI) = divUInt(accountMintableBAI, 10000);
        require(mErr == MathError.NO_ERROR, "BAI_MINT_AMOUNT_CALCULATION_FAILED");


        (mErr, accountMintableBAI) = subUInt(accountMintableBAI, vars.sumBorrowPlusEffects);
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.REJECTION), 0);
        }

        return (uint(Error.NO_ERROR), accountMintableBAI);
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the BAI token
     * @return The address of BAI
     */
    function getBAIAddress() public view returns (address) {
        return 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
    }
}
