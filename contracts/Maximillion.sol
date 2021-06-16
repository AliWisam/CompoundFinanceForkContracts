pragma solidity ^0.5.16;

import "./BBNB.sol";

/**
 * @title Btntex's Maximillion Contract
 * @author Btntex
 */
contract Maximillion {
    /**
     * @notice The default bBnb market to repay in
     */
    BBNB public bBnb;

    /**
     * @notice Construct a Maximillion to repay max in a BBNB market
     */
    constructor(BBNB bBnb_) public {
        bBnb = bBnb_;
    }

    /**
     * @notice msg.sender sends BNB to repay an account's borrow in the bBnb market
     * @dev The provided BNB is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, bBnb);
    }

    /**
     * @notice msg.sender sends BNB to repay an account's borrow in a bBnb market
     * @dev The provided BNB is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param bBnb_ The address of the bBnb contract to repay in
     */
    function repayBehalfExplicit(address borrower, BBNB bBnb_) public payable {
        uint received = msg.value;
        uint borrows = bBnb_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            bBnb_.repayBorrowBehalf.value(borrows)(borrower);
            msg.sender.transfer(received - borrows);
        } else {
            bBnb_.repayBorrowBehalf.value(received)(borrower);
        }
    }
}
