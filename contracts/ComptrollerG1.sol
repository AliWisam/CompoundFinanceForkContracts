pragma solidity ^0.5.16;

import "./BToken.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./PriceOracle.sol";
import "./ComptrollerInterface.sol";
import "./ComptrollerStorage.sol";
import "./Unitroller.sol";
import "./BTNT.sol";
import "./BAI.sol";

/**
 * @title Btntex's Comptroller Contract
 * @author Btntex
 */
contract ComptrollerG1 is ComptrollerV1Storage, ComptrollerInterfaceG1, ComptrollerErrorReporter, Exponential {
    /// @notice Emitted when an admin supports a market
    event MarketListed(BToken bToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(BToken bToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(BToken bToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(BToken bToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when maxAssets is changed by admin
    event NewMaxAssets(uint oldMaxAssets, uint newMaxAssets);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(BToken bToken, string action, bool pauseState);

    /// @notice Emitted when market btntex status is changed
    event MarketBtntex(BToken bToken, bool isBtntex);

    /// @notice Emitted when Btntex rate is changed
    event NewBtntexRate(uint oldBtntexRate, uint newBtntexRate);

    /// @notice Emitted when Btntex BAI rate is changed
    event NewBtntexBAIRate(uint oldBtntexBAIRate, uint newBtntexBAIRate);

    /// @notice Emitted when a new Btntex speed is calculated for a market
    event BtntexSpeedUpdated(BToken indexed bToken, uint newSpeed);

    /// @notice Emitted when BTNT is distributed to a supplier
    event DistributedSupplierBtntex(BToken indexed bToken, address indexed supplier, uint btntexDelta, uint btntexSupplyIndex);

    /// @notice Emitted when BTNT is distributed to a borrower
    event DistributedBorrowerBtntex(BToken indexed bToken, address indexed borrower, uint btntexDelta, uint btntexBorrowIndex);

    /// @notice Emitted when BTNT is distributed to a BAI minter
    event DistributedBAIMinterBtntex(address indexed baiMinter, uint btntexDelta, uint btntexBAIMintIndex);

    /// @notice Emitted when BAIController is changed
    event NewBAIController(BAIControllerInterface oldBAIController, BAIControllerInterface newBAIController);

    /// @notice Emitted when BAI mint rate is changed by admin
    event NewBAIMintRate(uint oldBAIMintRate, uint newBAIMintRate);

    /// @notice Emitted when protocol state is changed by admin
    event ActionProtocolPaused(bool state);

    /// @notice The threshold above which the flywheel transfers BTNT, in wei
    uint public constant btntexClaimThreshold = 0.001e18;

    /// @notice The initial Btntex index for a market
    uint224 public constant btntexInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    // liquidationIncentiveMantissa must be no less than this value
    uint internal constant liquidationIncentiveMinMantissa = 1.0e18; // 1.0

    // liquidationIncentiveMantissa must be no greater than this value
    uint internal constant liquidationIncentiveMaxMantissa = 1.5e18; // 1.5

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyProtocolAllowed {
        require(!protocolPaused, "protocol is paused");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier onlyListedMarket(BToken bToken) {
        require(markets[address(bToken)].isListed, "btntex market is not listed");
        _;
    }

    modifier validPauseState(bool state) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can");
        require(msg.sender == admin || state == true, "only admin can unpause");
        _;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (BToken[] memory) {
        return accountAssets[account];
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param bToken The bToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, BToken bToken) external view returns (bool) {
        return markets[address(bToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param bTokens The list of addresses of the bToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] calldata bTokens) external returns (uint[] memory) {
        uint len = bTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            results[i] = uint(addToMarketInternal(BToken(bTokens[i]), msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param bToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(BToken bToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(bToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cbtntot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower]) {
            // already joined
            return Error.NO_ERROR;
        }

        if (accountAssets[borrower].length >= maxAssets)  {
            // no space, cbtntot join
            return Error.TOO_MANY_ASSETS;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(bToken);

        emit MarketEntered(bToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param bTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address bTokenAddress) external returns (uint) {
        BToken bToken = BToken(bTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the bToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = bToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(bTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(bToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set bToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete bToken from the account’s list of assets */
        // In order to delete bToken, copy last item in list to location of item to be removed, reduce length by 1
        BToken[] storage userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint i;
        for (; i < len; i++) {
            if (userAssetList[i] == bToken) {
                userAssetList[i] = userAssetList[len - 1];
                userAssetList.length--;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(i < len);

        emit MarketExited(bToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param bToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address bToken, address minter, uint mintAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[bToken], "mint is paused");

        // Shh - currently unused
        mintAmount;

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateBtntexSupplyIndex(bToken);
        distributeSupplierBtntex(bToken, minter, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param bToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address bToken, address minter, uint actualMintAmount, uint mintTokens) external {
        // Shh - currently unused
        bToken;
        minter;
        actualMintAmount;
        mintTokens;
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param bToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of bTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address bToken, address redeemer, uint redeemTokens) external onlyProtocolAllowed returns (uint) {
        uint allowed = redeemAllowedInternal(bToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateBtntexSupplyIndex(bToken);
        distributeSupplierBtntex(bToken, redeemer, false);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address bToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[bToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, BToken(bToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall != 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param bToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address bToken, address redeemer, uint redeemAmount, uint redeemTokens) external {
        // Shh - currently unused
        bToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        require(redeemTokens != 0 || redeemAmount == 0, "redeemTokens zero");
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param bToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address bToken, address borrower, uint borrowAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[bToken], "borrow is paused");

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[bToken].accountMembership[borrower]) {
            // only bTokens may call borrowAllowed if borrower not in market
            require(msg.sender == bToken, "sender must be bToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(BToken(bToken), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
        }

        if (oracle.getUnderlyingPrice(BToken(bToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, BToken(bToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall != 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: BToken(bToken).borrowIndex()});
        updateBtntexBorrowIndex(bToken, borrowIndex);
        distributeBorrowerBtntex(bToken, borrower, borrowIndex, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param bToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address bToken, address borrower, uint borrowAmount) external {
        // Shh - currently unused
        bToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param bToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would repay the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address bToken,
        address payer,
        address borrower,
        uint repayAmount) external onlyProtocolAllowed returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: BToken(bToken).borrowIndex()});
        updateBtntexBorrowIndex(bToken, borrowIndex);
        distributeBorrowerBtntex(bToken, borrower, borrowIndex, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param bToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address bToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) external {
        // Shh - currently unused
        bToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external onlyProtocolAllowed returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[bTokenBorrowed].isListed || !markets[bTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, BToken(0), 0, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint borrowBalance = BToken(bTokenBorrowed).borrowBalanceStored(borrower);
        (MathError mathErr, uint maxClose) = mulScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        if (mathErr != MathError.NO_ERROR) {
            return uint(Error.MATH_ERROR);
        }
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) external {
        // Shh - currently unused
        bTokenBorrowed;
        bTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[bTokenCollateral].isListed || !markets[bTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (BToken(bTokenCollateral).comptroller() != BToken(bTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateBtntexSupplyIndex(bTokenCollateral);
        distributeSupplierBtntex(bTokenCollateral, borrower, false);
        distributeSupplierBtntex(bTokenCollateral, liquidator, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external {
        // Shh - currently unused
        bTokenCollateral;
        bTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param bToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of bTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address bToken, address src, address dst, uint transferTokens) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(bToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateBtntexSupplyIndex(bToken);
        distributeSupplierBtntex(bToken, src, false);
        distributeSupplierBtntex(bToken, dst, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param bToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of bTokens to transfer
     */
    function transferVerify(address bToken, address src, address dst, uint transferTokens) external {
        // Shh - currently unused
        bToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `bTokenBalance` is the number of bTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
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

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, BToken(0), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address bTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, BToken(bTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral bToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        BToken bTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;
        MathError mErr;

        // For each asset the account is in
        BToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            BToken asset = assets[i];

            // Read the balances and exchange rate from the bToken
            (oErr, vars.bTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> bnb (normalized price value)
            (mErr, vars.tokensToDenom) = mulExp3(vars.collateralFactor, vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumCollateral += tokensToDenom * bTokenBalance
            (mErr, vars.sumCollateral) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.bTokenBalance, vars.sumCollateral);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // Calculate effects of interacting with bTokenModify
            if (asset == bTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }
            }
        }

        /// @dev BAI Integration^
        (mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, mintedBAIs[account]);
        if (mErr != MathError.NO_ERROR) {
            return (Error.MATH_ERROR, 0, 0);
        }
        /// @dev BAI Integration$

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in bToken.liquidateBorrowFresh)
     * @param bTokenBorrowed The address of the borrowed bToken
     * @param bTokenCollateral The address of the collateral bToken
     * @param actualRepayAmount The amount of bTokenBorrowed underlying to convert into bTokenCollateral tokens
     * @return (errorCode, number of bTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address bTokenBorrowed, address bTokenCollateral, uint actualRepayAmount) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(BToken(bTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(BToken(bTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = BToken(bTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;

        (mathErr, numerator) = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, denominator) = mulExp(priceCollateralMantissa, exchangeRateMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, ratio) = divExp(numerator, denominator);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, seizeTokens) = mulScalarTruncate(ratio, actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_CLOSE_FACTOR_OWNER_CHECK);
        }

        Exp memory newCloseFactorExp = Exp({mantissa: newCloseFactorMantissa});
        Exp memory lowLimit = Exp({mantissa: closeFactorMinMantissa});
        if (lessThanOrEqualExp(newCloseFactorExp, lowLimit)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        Exp memory highLimit = Exp({mantissa: closeFactorMaxMantissa});
        if (lessThanExp(highLimit, newCloseFactorExp)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, newCloseFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param bToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(BToken bToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(bToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(bToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(bToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets maxAssets which controls how many markets can be entered
      * @dev Admin function to set maxAssets
      * @param newMaxAssets New max assets
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setMaxAssets(uint newMaxAssets) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_MAX_ASSETS_OWNER_CHECK);
        }

        uint oldMaxAssets = maxAssets;
        maxAssets = newMaxAssets;
        emit NewMaxAssets(oldMaxAssets, newMaxAssets);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Check de-scaled min <= newLiquidationIncentive <= max
        Exp memory newLiquidationIncentive = Exp({mantissa: newLiquidationIncentiveMantissa});
        Exp memory minLiquidationIncentive = Exp({mantissa: liquidationIncentiveMinMantissa});
        if (lessThanExp(newLiquidationIncentive, minLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        Exp memory maxLiquidationIncentive = Exp({mantissa: liquidationIncentiveMaxMantissa});
        if (lessThanExp(maxLiquidationIncentive, newLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param bToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(BToken bToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(bToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        bToken.isBToken(); // Sanity check to make sure its really a BToken

        markets[address(bToken)] = Market({isListed: true, isBtntex: false, collateralFactorMantissa: 0});

        _addMarketInternal(bToken);

        emit MarketListed(bToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(BToken bToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != bToken, "market already added");
        }
        allMarkets.push(bToken);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, newPauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(BToken bToken, bool state) public onlyListedMarket(bToken) validPauseState(state) returns (bool) {
        mintGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(BToken bToken, bool state) public onlyListedMarket(bToken) validPauseState(state) returns (bool) {
        borrowGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public validPauseState(state) returns (bool) {
        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public validPauseState(state) returns (bool) {
        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _setMintBAIPaused(bool state) public validPauseState(state) returns (bool) {
        mintBAIGuardianPaused = state;
        emit ActionPaused("MintBAI", state);
        return state;
    }

    function _setRepayBAIPaused(bool state) public validPauseState(state) returns (bool) {
        repayBAIGuardianPaused = state;
        emit ActionPaused("RepayBAI", state);
        return state;
    }
    /**
     * @notice Set whole protocol pause/unpause state
     */
    function _setProtocolPaused(bool state) public onlyAdmin returns(bool) {
        protocolPaused = state;
        emit ActionProtocolPaused(state);
        return state;
    }

    /**
      * @notice Sets a new BAI controller
      * @dev Admin function to set a new BAI controller
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setBAIController(BAIControllerInterface baiController_) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_BAICONTROLLER_OWNER_CHECK);
        }

        BAIControllerInterface oldRate = baiController;
        baiController = baiController_;
        emit NewBAIController(oldRate, baiController_);
    }

    function _setBAIMintRate(uint newBAIMintRate) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_BAI_MINT_RATE_CHECK);
        }

        uint oldBAIMintRate = baiMintRate;
        baiMintRate = newBAIMintRate;
        emit NewBAIMintRate(oldBAIMintRate, newBAIMintRate);

        return uint(Error.NO_ERROR);
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can");
        require(unitroller._acceptImplementation() == 0, "not authorized");
    }

    /*** Btntex Distribution ***/

    /**
     * @notice Recalculate and update Btntex speeds for all Btntex markets
     */
    function refreshBtntexSpeeds() public {
        require(msg.sender == tx.origin, "only externally owned accounts can");
        refreshBtntexSpeedsInternal();
    }

    function refreshBtntexSpeedsInternal() internal {
        uint i;
        BToken bToken;

        for (i = 0; i < allMarkets.length; i++) {
            bToken = allMarkets[i];
            Exp memory borrowIndex = Exp({mantissa: bToken.borrowIndex()});
            updateBtntexSupplyIndex(address(bToken));
            updateBtntexBorrowIndex(address(bToken), borrowIndex);
        }

        Exp memory totalUtility = Exp({mantissa: 0});
        Exp[] memory utilities = new Exp[](allMarkets.length);
        for (i = 0; i < allMarkets.length; i++) {
            bToken = allMarkets[i];
            if (markets[address(bToken)].isBtntex) {
                Exp memory assetPrice = Exp({mantissa: oracle.getUnderlyingPrice(bToken)});
                Exp memory utility = mul_(assetPrice, bToken.totalBorrows());
                utilities[i] = utility;
                totalUtility = add_(totalUtility, utility);
            }
        }

        for (i = 0; i < allMarkets.length; i++) {
            bToken = allMarkets[i];
            uint newSpeed = totalUtility.mantissa > 0 ? mul_(btntexRate, div_(utilities[i], totalUtility)) : 0;
            btntexSpeeds[address(bToken)] = newSpeed;
            emit BtntexSpeedUpdated(bToken, newSpeed);
        }
    }

    /**
     * @notice Accrue BTNT to the market by updating the supply index
     * @param bToken The market whose supply index to update
     */
    function updateBtntexSupplyIndex(address bToken) internal {
        BtntexMarketState storage supplyState = btntexSupplyState[bToken];
        uint supplySpeed = btntexSpeeds[bToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = BToken(bToken).totalSupply();
            uint btntexAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(btntexAccrued, supplyTokens) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: supplyState.index}), ratio);
            btntexSupplyState[bToken] = BtntexMarketState({
                index: safe224(index.mantissa, "new index overflows"),
                block: safe32(blockNumber, "block number overflows")
            });
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @notice Accrue BTNT to the market by updating the borrow index
     * @param bToken The market whose borrow index to update
     */
    function updateBtntexBorrowIndex(address bToken, Exp memory marketBorrowIndex) internal {
        BtntexMarketState storage borrowState = btntexBorrowState[bToken];
        uint borrowSpeed = btntexSpeeds[bToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(BToken(bToken).totalBorrows(), marketBorrowIndex);
            uint btntexAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(btntexAccrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowState.index}), ratio);
            btntexBorrowState[bToken] = BtntexMarketState({
                index: safe224(index.mantissa, "new index overflows"),
                block: safe32(blockNumber, "block number overflows")
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @notice Accrue BTNT to by updating the BAI minter index
     */
    function updateBtntexBAIMintIndex() internal {
        if (address(baiController) != address(0)) {
            baiController.updateBtntexBAIMintIndex();
        }
    }

    /**
     * @notice Calculate BTNT accrued by a supplier and possibly transfer it to them
     * @param bToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute BTNT to
     */
    function distributeSupplierBtntex(address bToken, address supplier, bool distributeAll) internal {
        BtntexMarketState storage supplyState = btntexSupplyState[bToken];
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        Double memory supplierIndex = Double({mantissa: btntexSupplierIndex[bToken][supplier]});
        btntexSupplierIndex[bToken][supplier] = supplyIndex.mantissa;

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = btntexInitialIndex;
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint supplierTokens = BToken(bToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(btntexAccrued[supplier], supplierDelta);
        btntexAccrued[supplier] = transferBTNT(supplier, supplierAccrued, distributeAll ? 0 : btntexClaimThreshold);
        emit DistributedSupplierBtntex(BToken(bToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

    /**
     * @notice Calculate BTNT accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param bToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute BTNT to
     */
    function distributeBorrowerBtntex(address bToken, address borrower, Exp memory marketBorrowIndex, bool distributeAll) internal {
        BtntexMarketState storage borrowState = btntexBorrowState[bToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({mantissa: btntexBorrowerIndex[bToken][borrower]});
        btntexBorrowerIndex[bToken][borrower] = borrowIndex.mantissa;

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(BToken(bToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(btntexAccrued[borrower], borrowerDelta);
            btntexAccrued[borrower] = transferBTNT(borrower, borrowerAccrued, distributeAll ? 0 : btntexClaimThreshold);
            emit DistributedBorrowerBtntex(BToken(bToken), borrower, borrowerDelta, borrowIndex.mantissa);
        }
    }

    /**
     * @notice Calculate BTNT accrued by a BAI minter and possibly transfer it to them
     * @dev BAI minters will not begin to accrue until after the first interaction with the protocol.
     * @param baiMinter The address of the BAI minter to distribute BTNT to
     */
    function distributeBAIMinterBtntex(address baiMinter, bool distributeAll) internal {
        if (address(baiController) != address(0)) {
            uint baiMinterAccrued;
            uint baiMinterDelta;
            uint baiMintIndexMantissa;
            uint err;
            (err, baiMinterAccrued, baiMinterDelta, baiMintIndexMantissa) = baiController.calcDistributeBAIMinterBtntex(baiMinter);
            if (err == uint(Error.NO_ERROR)) {
                btntexAccrued[baiMinter] = transferBTNT(baiMinter, baiMinterAccrued, distributeAll ? 0 : btntexClaimThreshold);
                emit DistributedBAIMinterBtntex(baiMinter, baiMinterDelta, baiMintIndexMantissa);
            }
        }
    }

    /**
     * @notice Transfer BTNT to the user, if they are above the threshold
     * @dev Note: If there is not enough BTNT, we do not perform the transfer all.
     * @param user The address of the user to transfer BTNT to
     * @param userAccrued The amount of BTNT to (possibly) transfer
     * @return The amount of BTNT which was NOT transferred to the user
     */
    function transferBTNT(address user, uint userAccrued, uint threshold) internal returns (uint) {
        if (userAccrued >= threshold && userAccrued > 0) {
            BTNT btnt = BTNT(getBTNTAddress());
            uint btntRemaining = btnt.balanceOf(address(this));
            if (userAccrued <= btntRemaining) {
                btnt.transfer(user, userAccrued);
                return 0;
            }
        }
        return userAccrued;
    }

    /**
     * @notice Claim all the btnt accrued by holder in all markets and BAI
     * @param holder The address to claim BTNT for
     */
    function claimBtntex(address holder) public {
        return claimBtntex(holder, allMarkets);
    }

    /**
     * @notice Claim all the btnt accrued by holder in the specified markets
     * @param holder The address to claim BTNT for
     * @param bTokens The list of markets to claim BTNT in
     */
    function claimBtntex(address holder, BToken[] memory bTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimBtntex(holders, bTokens, true, true);
    }

    /**
     * @notice Claim all btnt accrued by the holders
     * @param holders The addresses to claim BTNT for
     * @param bTokens The list of markets to claim BTNT in
     * @param borrowers Whether or not to claim BTNT earned by borrowing
     * @param suppliers Whether or not to claim BTNT earned by supplying
     */
    function claimBtntex(address[] memory holders, BToken[] memory bTokens, bool borrowers, bool suppliers) public {
        uint j;
        updateBtntexBAIMintIndex();
        for (j = 0; j < holders.length; j++) {
            distributeBAIMinterBtntex(holders[j], true);
        }
        for (uint i = 0; i < bTokens.length; i++) {
            BToken bToken = bTokens[i];
            require(markets[address(bToken)].isListed, "not listed market");
            if (borrowers) {
                Exp memory borrowIndex = Exp({mantissa: bToken.borrowIndex()});
                updateBtntexBorrowIndex(address(bToken), borrowIndex);
                for (j = 0; j < holders.length; j++) {
                    distributeBorrowerBtntex(address(bToken), holders[j], borrowIndex, true);
                }
            }
            if (suppliers) {
                updateBtntexSupplyIndex(address(bToken));
                for (j = 0; j < holders.length; j++) {
                    distributeSupplierBtntex(address(bToken), holders[j], true);
                }
            }
        }
    }

    /*** Btntex Distribution Admin ***/

    /**
     * @notice Set the amount of BTNT distributed per block
     * @param btntexRate_ The amount of BTNT wei per block to distribute
     */
    function _setBtntexRate(uint btntexRate_) public onlyAdmin {
        uint oldRate = btntexRate;
        btntexRate = btntexRate_;
        emit NewBtntexRate(oldRate, btntexRate_);

        refreshBtntexSpeedsInternal();
    }

    /**
     * @notice Set the amount of BTNT distributed per block to BAI Mint
     * @param btntexBAIRate_ The amount of BTNT wei per block to distribute to BAI Mint
     */
    function _setBtntexBAIRate(uint btntexBAIRate_) public {
        require(msg.sender == admin, "only admin can");

        uint oldBAIRate = btntexBAIRate;
        btntexBAIRate = btntexBAIRate_;
        emit NewBtntexBAIRate(oldBAIRate, btntexBAIRate_);
    }

    /**
     * @notice Add markets to btntexMarkets, allowing them to earn BTNT in the flywheel
     * @param bTokens The addresses of the markets to add
     */
    function _addBtntexMarkets(address[] calldata bTokens) external onlyAdmin {
        for (uint i = 0; i < bTokens.length; i++) {
            _addBtntexMarketInternal(bTokens[i]);
        }

        refreshBtntexSpeedsInternal();
    }

    function _addBtntexMarketInternal(address bToken) internal {
        Market storage market = markets[bToken];
        require(market.isListed, "btntex market is not listed");
        require(!market.isBtntex, "btntex market already added");

        market.isBtntex = true;
        emit MarketBtntex(BToken(bToken), true);

        if (btntexSupplyState[bToken].index == 0 && btntexSupplyState[bToken].block == 0) {
            btntexSupplyState[bToken] = BtntexMarketState({
                index: btntexInitialIndex,
                block: safe32(getBlockNumber(), "block number overflows")
            });
        }

        if (btntexBorrowState[bToken].index == 0 && btntexBorrowState[bToken].block == 0) {
            btntexBorrowState[bToken] = BtntexMarketState({
                index: btntexInitialIndex,
                block: safe32(getBlockNumber(), "block number overflows")
            });
        }
    }

    function _initializeBtntexBAIState(uint blockNumber) public {
        require(msg.sender == admin, "only admin can");
        if (address(baiController) != address(0)) {
            baiController._initializeBtntexBAIState(blockNumber);
        }
    }

    /**
     * @notice Remove a market from btntexMarkets, preventing it from earning BTNT in the flywheel
     * @param bToken The address of the market to drop
     */
    function _dropBtntexMarket(address bToken) public onlyAdmin {
        Market storage market = markets[bToken];
        require(market.isBtntex == true, "not btntex market");

        market.isBtntex = false;
        emit MarketBtntex(BToken(bToken), false);

        refreshBtntexSpeedsInternal();
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (BToken[] memory) {
        return allMarkets;
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the BTNT token
     * @return The address of BTNT
     */
    function getBTNTAddress() public view returns (address) {
        return 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    }

    /*** BAI functions ***/

    /**
     * @notice Set the minted BAI amount of the `owner`
     * @param owner The address of the account to set
     * @param amount The amount of BAI to set to the account
     * @return The number of minted BAI by `owner`
     */
    function setMintedBAIOf(address owner, uint amount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintBAIGuardianPaused && !repayBAIGuardianPaused, "BAI is paused");
        // Check caller is baiController
        if (msg.sender != address(baiController)) {
            return fail(Error.REJECTION, FailureInfo.SET_MINTED_BAI_REJECTION);
        }
        mintedBAIs[owner] = amount;

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Mint BAI
     */
    function mintBAI(uint mintBAIAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintBAIGuardianPaused, "mintBAI is paused");

        // Keep the flywheel moving
        updateBtntexBAIMintIndex();
        distributeBAIMinterBtntex(msg.sender, false);
        return baiController.mintBAI(msg.sender, mintBAIAmount);
    }

    /**
     * @notice Repay BAI
     */
    function repayBAI(uint repayBAIAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!repayBAIGuardianPaused, "repayBAI is paused");

        // Keep the flywheel moving
        updateBtntexBAIMintIndex();
        distributeBAIMinterBtntex(msg.sender, false);
        return baiController.repayBAI(msg.sender, repayBAIAmount);
    }

    /**
     * @notice Get the minted BAI amount of the `owner`
     * @param owner The address of the account to query
     * @return The number of minted BAI by `owner`
     */
    function mintedBAIOf(address owner) external view returns (uint) {
        return mintedBAIs[owner];
    }

    /**
     * @notice Get Mintable BAI amount
     */
    function getMintableBAI(address minter) external view returns (uint, uint) {
        return baiController.getMintableBAI(minter);
    }
}
