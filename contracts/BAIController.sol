pragma solidity ^0.5.16;

import "./BToken.sol";
import "./PriceOracle.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./BAIControllerStorage.sol";
import "./BAIUnitroller.sol";
import "./BAI.sol";

interface ComptrollerImplInterface {
    function protocolPaused() external view returns (bool);
    function mintedBAIs(address account) external view returns (uint);
    function baiMintRate() external view returns (uint);
    function btntexBAIRate() external view returns (uint);
    function btntexAccrued(address account) external view returns(uint);
    function getAssetsIn(address account) external view returns (BToken[] memory);
    function oracle() external view returns (PriceOracle);

    function distributeBAIMinterBtntex(address baiMinter) external;
}

/**
 * @title Btntex's BAI Comptroller Contract
 * @author Btntex
 */
contract BAIController is BAIControllerStorageG2, BAIControllerErrorReporter, Exponential {

    /// @notice Emitted when Comptroller is changed
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);

    /**
     * @notice Event emitted when BAI is minted
     */
    event MintBAI(address minter, uint mintBAIAmount);

    /**
     * @notice Event emitted when BAI is repaid
     */
    event RepayBAI(address payer, address borrower, uint repayBAIAmount);

    /// @notice The initial Btntex index for a market
    uint224 public constant btntexInitialIndex = 1e36;

    /**
     * @notice Event emitted when a borrow is liquidated
     */
    event LiquidateBAI(address liquidator, address borrower, uint repayAmount, address bTokenCollateral, uint seizeTokens);

    /**
     * @notice Emitted when treasury guardian is changed
     */
    event NewTreasuryGuardian(address oldTreasuryGuardian, address newTreasuryGuardian);

    /**
     * @notice Emitted when treasury address is changed
     */
    event NewTreasuryAddress(address oldTreasuryAddress, address newTreasuryAddress);

    /**
     * @notice Emitted when treasury percent is changed
     */
    event NewTreasuryPercent(uint oldTreasuryPercent, uint newTreasuryPercent);

    /**
     * @notice Event emitted when BAIs are minted and fee are transferred
     */
    event MintFee(address minter, uint feeAmount);

    /*** Main Actions ***/
    struct MintLocalVars {
        Error err;
        MathError mathErr;
        uint mintAmount;
    }

    function mintBAI(uint mintBAIAmount) external nonReentrant returns (uint) {
        if(address(comptroller) != address(0)) {
            require(mintBAIAmount > 0, "mintBAIAmount cbtntt be zero");

            require(!ComptrollerImplInterface(address(comptroller)).protocolPaused(), "protocol is paused");

            MintLocalVars memory vars;

            address minter = msg.sender;

            // Keep the flywheel moving
            updateBtntexBAIMintIndex();
            ComptrollerImplInterface(address(comptroller)).distributeBAIMinterBtntex(minter);

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

            (mErr, accountMintBAINew) = addUInt(ComptrollerImplInterface(address(comptroller)).mintedBAIs(minter), mintBAIAmount);
            require(mErr == MathError.NO_ERROR, "BAI_MINT_AMOUNT_CALCULATION_FAILED");
            uint error = comptroller.setMintedBAIOf(minter, accountMintBAINew);
            if (error != 0 ) {
                return error;
            }

            uint feeAmount;
            uint remainedAmount;
            vars.mintAmount = mintBAIAmount;
            if (treasuryPercent != 0) {
                (vars.mathErr, feeAmount) = mulUInt(vars.mintAmount, treasuryPercent);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, feeAmount) = divUInt(feeAmount, 1e18);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, remainedAmount) = subUInt(vars.mintAmount, feeAmount);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                BAI(getBAIAddress()).mint(treasuryAddress, feeAmount);

                emit MintFee(minter, feeAmount);
            } else {
                remainedAmount = vars.mintAmount;
            }

            BAI(getBAIAddress()).mint(minter, remainedAmount);

            emit MintBAI(minter, remainedAmount);

            return uint(Error.NO_ERROR);
        }
    }

    /**
     * @notice Repay BAI
     */
    function repayBAI(uint repayBAIAmount) external nonReentrant returns (uint, uint) {
        if(address(comptroller) != address(0)) {
            require(repayBAIAmount > 0, "repayBAIAmount cbtntt be zero");

            require(!ComptrollerImplInterface(address(comptroller)).protocolPaused(), "protocol is paused");

            address payer = msg.sender;

            updateBtntexBAIMintIndex();
            ComptrollerImplInterface(address(comptroller)).distributeBAIMinterBtntex(payer);

            return repayBAIFresh(msg.sender, msg.sender, repayBAIAmount);
        }
    }

    /**
     * @notice Repay BAI Internal
     * @notice Borrowed BAIs are repaid by another user (possibly the borrower).
     * @param payer the account paying off the BAI
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of BAI being returned
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBAIFresh(address payer, address borrower, uint repayAmount) internal returns (uint, uint) {
        uint actualBurnAmount;

        uint baiBalanceBorrower = ComptrollerImplInterface(address(comptroller)).mintedBAIs(borrower);

        if(baiBalanceBorrower > repayAmount) {
            actualBurnAmount = repayAmount;
        } else {
            actualBurnAmount = baiBalanceBorrower;
        }

        MathError mErr;
        uint accountBAINew;

        BAI(getBAIAddress()).burn(payer, actualBurnAmount);

        (mErr, accountBAINew) = subUInt(baiBalanceBorrower, actualBurnAmount);
        require(mErr == MathError.NO_ERROR, "BAI_BURN_AMOUNT_CALCULATION_FAILED");

        uint error = comptroller.setMintedBAIOf(borrower, accountBAINew);
        if (error != 0) {
            return (error, 0);
        }
        emit RepayBAI(payer, borrower, actualBurnAmount);

        return (uint(Error.NO_ERROR), actualBurnAmount);
    }

    /**
     * @notice The sender liquidates the bai minters collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of bai to be liquidated
     * @param bTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateBAI(address borrower, uint repayAmount, BTokenInterface bTokenCollateral) external nonReentrant returns (uint, uint) {
        require(!ComptrollerImplInterface(address(comptroller)).protocolPaused(), "protocol is paused");

        uint error = bTokenCollateral.accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted liquidation failed
            return (fail(Error(error), FailureInfo.BAI_LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED), 0);
        }

        // liquidateBAIFresh emits borrow-specific logs on errors, so we don't need to
        return liquidateBAIFresh(msg.sender, borrower, repayAmount, bTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral by repay borrowers BAI.
     *  The collateral seized is transferred to the liquidator.
     * @param liquidator The address repaying the BAI and seizing collateral
     * @param borrower The borrower of this BAI to be liquidated
     * @param bTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the BAI to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment BAI.
     */
    function liquidateBAIFresh(address liquidator, address borrower, uint repayAmount, BTokenInterface bTokenCollateral) internal returns (uint, uint) {
        if(address(comptroller) != address(0)) {
            /* Fail if liquidate not allowed */
            uint allowed = comptroller.liquidateBorrowAllowed(address(this), address(bTokenCollateral), liquidator, borrower, repayAmount);
            if (allowed != 0) {
                return (failOpaque(Error.REJECTION, FailureInfo.BAI_LIQUIDATE_COMPTROLLER_REJECTION, allowed), 0);
            }

            /* Verify bTokenCollateral market's block number equals current block number */
            //if (bTokenCollateral.accrualBlockNumber() != accrualBlockNumber) {
            if (bTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
                return (fail(Error.REJECTION, FailureInfo.BAI_LIQUIDATE_COLLATERAL_FRESHNESS_CHECK), 0);
            }

            /* Fail if borrower = liquidator */
            if (borrower == liquidator) {
                return (fail(Error.REJECTION, FailureInfo.BAI_LIQUIDATE_LIQUIDATOR_IS_BORROWER), 0);
            }

            /* Fail if repayAmount = 0 */
            if (repayAmount == 0) {
                return (fail(Error.REJECTION, FailureInfo.BAI_LIQUIDATE_CLOSE_AMOUNT_IS_ZERO), 0);
            }

            /* Fail if repayAmount = -1 */
            if (repayAmount == uint(-1)) {
                return (fail(Error.REJECTION, FailureInfo.BAI_LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX), 0);
            }


            /* Fail if repayBAI fails */
            (uint repayBorrowError, uint actualRepayAmount) = repayBAIFresh(liquidator, borrower, repayAmount);
            if (repayBorrowError != uint(Error.NO_ERROR)) {
                return (fail(Error(repayBorrowError), FailureInfo.BAI_LIQUIDATE_REPAY_BORROW_FRESH_FAILED), 0);
            }

            /////////////////////////
            // EFFECTS & INTERACTIONS
            // (No safe failures beyond this point)

            /* We calculate the number of collateral tokens that will be seized */
            (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateBAICalculateSeizeTokens(address(bTokenCollateral), actualRepayAmount);
            require(amountSeizeError == uint(Error.NO_ERROR), "BAI_LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED");

            /* Revert if borrower collateral token balance < seizeTokens */
            require(bTokenCollateral.balanceOf(borrower) >= seizeTokens, "BAI_LIQUIDATE_SEIZE_TOO_MUCH");

            uint seizeError;
            seizeError = bTokenCollateral.seize(liquidator, borrower, seizeTokens);

            /* Revert if seize tokens fails (since we cbtntot be sure of side effects) */
            require(seizeError == uint(Error.NO_ERROR), "token seizure failed");

            /* We emit a LiquidateBorrow event */
            emit LiquidateBAI(liquidator, borrower, actualRepayAmount, address(bTokenCollateral), seizeTokens);

            /* We call the defense hook */
            comptroller.liquidateBorrowVerify(address(this), address(bTokenCollateral), liquidator, borrower, actualRepayAmount, seizeTokens);

            return (uint(Error.NO_ERROR), actualRepayAmount);
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

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Accrue BTNT to by updating the BAI minter index
     */
    function updateBtntexBAIMintIndex() public returns (uint) {
        uint baiMinterSpeed = ComptrollerImplInterface(address(comptroller)).btntexBAIRate();
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

        return uint(Error.NO_ERROR);
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
        uint baiMinterAmount = ComptrollerImplInterface(address(comptroller)).mintedBAIs(baiMinter);
        uint baiMinterDelta = mul_(baiMinterAmount, deltaIndex);
        uint baiMinterAccrued = add_(ComptrollerImplInterface(address(comptroller)).btntexAccrued(baiMinter), baiMinterDelta);
        return (uint(Error.NO_ERROR), baiMinterAccrued, baiMinterDelta, baiMintIndex.mantissa);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new comptroller
      * @dev Admin function to set a new comptroller
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setComptroller(ComptrollerInterface comptroller_) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        ComptrollerInterface oldComptroller = comptroller;
        comptroller = comptroller_;
        emit NewComptroller(oldComptroller, comptroller_);

        return uint(Error.NO_ERROR);
    }

    function _become(BAIUnitroller unitroller) external {
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
        PriceOracle oracle = ComptrollerImplInterface(address(comptroller)).oracle();
        BToken[] memory enteredMarkets = ComptrollerImplInterface(address(comptroller)).getAssetsIn(minter);

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

        (mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, ComptrollerImplInterface(address(comptroller)).mintedBAIs(minter));
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mErr, accountMintableBAI) = mulUInt(vars.sumSupply, ComptrollerImplInterface(address(comptroller)).baiMintRate());
        require(mErr == MathError.NO_ERROR, "BAI_MINT_AMOUNT_CALCULATION_FAILED");

        (mErr, accountMintableBAI) = divUInt(accountMintableBAI, 10000);
        require(mErr == MathError.NO_ERROR, "BAI_MINT_AMOUNT_CALCULATION_FAILED");


        (mErr, accountMintableBAI) = subUInt(accountMintableBAI, vars.sumBorrowPlusEffects);
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.REJECTION), 0);
        }

        return (uint(Error.NO_ERROR), accountMintableBAI);
    }

    function _setTreasuryData(address newTreasuryGuardian, address newTreasuryAddress, uint newTreasuryPercent) external returns (uint) {
        // Check caller is admin
        if (!(msg.sender == admin || msg.sender == treasuryGuardian)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_TREASURY_OWNER_CHECK);
        }

        require(newTreasuryPercent < 1e18, "treasury percent cap overflow");

        address oldTreasuryGuardian = treasuryGuardian;
        address oldTreasuryAddress = treasuryAddress;
        uint oldTreasuryPercent = treasuryPercent;

        treasuryGuardian = newTreasuryGuardian;
        treasuryAddress = newTreasuryAddress;
        treasuryPercent = newTreasuryPercent;

        emit NewTreasuryGuardian(oldTreasuryGuardian, newTreasuryGuardian);
        emit NewTreasuryAddress(oldTreasuryAddress, newTreasuryAddress);
        emit NewTreasuryPercent(oldTreasuryPercent, newTreasuryPercent);

        return uint(Error.NO_ERROR);
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

    function initialize() onlyAdmin public {
        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
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
}
