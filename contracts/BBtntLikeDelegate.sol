pragma solidity ^0.5.16;

import "./BBep20Delegate.sol";

interface BtntLike {
  function delegate(address delegatee) external;
}

/**
 * @title Btntex's BBtntLikeDelegate Contract
 * @notice BTokens which can 'delegate votes' of their underlying BEP-20
 * @author Btntex
 */
contract BBtntLikeDelegate is BBep20Delegate {
  /**
   * @notice Construct an empty delegate
   */
  constructor() public BBep20Delegate() {}

  /**
   * @notice Admin call to delegate the votes of the BTNT-like underlying
   * @param btntLikeDelegatee The address to delegate votes to
   */
  function _delegateBtntLikeTo(address btntLikeDelegatee) external {
    require(msg.sender == admin, "only the admin may set the btnt-like delegate");
    BtntLike(underlying).delegate(btntLikeDelegatee);
  }
}