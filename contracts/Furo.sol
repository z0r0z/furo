// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.10;

import "./interfaces/IFuro.sol";
import "./utils/BoringBatchable.sol";
import "./utils/BoringOwnable.sol";

contract Furo is IFuro, BoringOwnable, BoringBatchable {
    IBentoBoxMinimal public immutable bentoBox;
    address public immutable wETH;

    uint256 public streamIds;

    mapping(uint256 => Stream) public streams;
    mapping(ISwapReceiver => bool) public whitelistedReceivers;

    // custom errors
    error NotSenderOrRecipient();
    error InvalidStream();
    error InvalidAddressZero();
    error InvalidStartTime();
    error InvalidEndTime();
    error InvalidWithdrawTooMuch();
    error InvalidSwapper();
    error NotRecipient();
    error NotSender();
    error ReceivedTooLess();

    modifier onlySenderOrRecipient(uint256 streamId) {
        if (
            msg.sender != streams[streamId].sender &&
            msg.sender != streams[streamId].recipient
        ) {
            revert NotSenderOrRecipient();
        }
        _;
    }

    constructor(IBentoBoxMinimal _bentoBox, address _wETH) {
        bentoBox = _bentoBox;
        wETH = _wETH;
        streamIds = 1;
        _bentoBox.registerProtocol();
    }

    function setBentoBoxApproval(
        address user,
        bool approved,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        bentoBox.setMasterContractApproval(
            user,
            address(this),
            approved,
            v,
            r,
            s
        );
    }

    function createStream(
        address recipient,
        address token,
        uint64 startTime,
        uint64 endTime,
        uint256 amount, /// @dev in token amount and not in shares
        bool fromBentoBox
    )
        external
        payable
        override
        returns (uint256 streamId, uint256 depositedShares)
    {
        if (startTime < block.timestamp) revert InvalidStartTime();
        if (endTime <= startTime) revert InvalidEndTime();

        depositedShares = _depositToken(
            token,
            msg.sender,
            address(this),
            amount,
            fromBentoBox
        );

        streamId = streamIds++;

        streams[streamId] = Stream({
            sender: msg.sender,
            recipient: recipient,
            token: token,
            depositedShares: uint128(depositedShares),
            withdrawnShares: 0,
            startTime: startTime,
            endTime: endTime
        });

        emit LogCreateStream(
            streamId,
            msg.sender,
            recipient,
            token,
            depositedShares,
            startTime,
            endTime,
            fromBentoBox
        );
    }

    function withdrawFromStream(
        uint256 streamId,
        uint256 sharesToWithdraw,
        address withdrawTo,
        bool toBentoBox
    )
        external
        override
        onlySenderOrRecipient(streamId)
        returns (uint256 recipientBalance, address to)
    {
        Stream storage stream = streams[streamId];
        (, recipientBalance) = _balanceOf(stream);
        if (recipientBalance < sharesToWithdraw)
            revert InvalidWithdrawTooMuch();
        stream.withdrawnShares += uint128(sharesToWithdraw);
        if (msg.sender == stream.recipient && withdrawTo != address(0)) {
            to = withdrawTo;
        } else {
            to = stream.recipient;
        }

        _transferToken(
            stream.token,
            address(this),
            to,
            sharesToWithdraw,
            toBentoBox
        );

        emit LogWithdrawFromStream(
            streamId,
            sharesToWithdraw,
            withdrawTo,
            stream.token,
            toBentoBox
        );
    }

    function withdrawSwap(
        uint256 streamId,
        uint256 sharesToWithdraw,
        address toToken,
        uint256 amountOutMin,
        ISwapReceiver swapReceiver,
        bytes calldata data,
        bool toBentoBox
    ) external override returns (uint256 recipientBalance) {
        if (!whitelistedReceivers[swapReceiver]) revert InvalidSwapper();
        Stream storage stream = streams[streamId];
        if (msg.sender != stream.recipient) revert NotRecipient();
        (, recipientBalance) = _balanceOf(stream);
        require(
            recipientBalance >= sharesToWithdraw,
            "Furo: withdraw too much"
        );
        stream.withdrawnShares += uint128(sharesToWithdraw);
        uint256 toTokenBalanceBefore = bentoBox.balanceOf(
            toToken,
            address(this)
        );
        _transferToken(
            stream.token,
            address(this),
            address(swapReceiver),
            sharesToWithdraw,
            true
        );
        swapReceiver.onSwapReceive(
            stream.token,
            toToken,
            sharesToWithdraw,
            amountOutMin,
            data
        );
        uint256 toTokenBalanceAfter = bentoBox.balanceOf(
            toToken,
            address(this)
        );
        if (toTokenBalanceAfter < toTokenBalanceBefore + amountOutMin)
            revert ReceivedTooLess();

        _transferToken(
            toToken,
            address(this),
            stream.recipient,
            toTokenBalanceAfter - toTokenBalanceBefore,
            toBentoBox
        );

        emit LogWithdrawFromStream(
            streamId,
            sharesToWithdraw,
            stream.recipient,
            toToken,
            toBentoBox
        );
    }

    function cancelStream(uint256 streamId, bool toBentoBox)
        external
        override
        onlySenderOrRecipient(streamId)
        returns (uint256 senderBalance, uint256 recipientBalance)
    {
        Stream memory stream = streams[streamId];
        (senderBalance, recipientBalance) = _balanceOf(stream);

        delete streams[streamId];

        _transferToken(
            stream.token,
            address(this),
            stream.recipient,
            recipientBalance,
            toBentoBox
        );
        _transferToken(
            stream.token,
            address(this),
            stream.sender,
            senderBalance,
            toBentoBox
        );

        emit LogCancelStream(
            streamId,
            senderBalance,
            recipientBalance,
            stream.token,
            toBentoBox
        );
    }

    function getStream(uint256 streamId)
        external
        view
        override
        returns (Stream memory)
    {
        return streams[streamId];
    }

    function balanceOf(uint256 streamId)
        external
        view
        override
        returns (uint256 senderBalance, uint256 recipientBalance)
    {
        return _balanceOf(streams[streamId]);
    }

    function _balanceOf(Stream memory stream)
        internal
        view
        returns (uint256 senderBalance, uint256 recipientBalance)
    {
        if (block.timestamp <= stream.startTime) {
            senderBalance = stream.depositedShares;
            recipientBalance = 0;
        } else if (stream.endTime <= block.timestamp) {
            recipientBalance = stream.depositedShares - stream.withdrawnShares;
            senderBalance = 0;
        } else {
            uint256 timeDelta = block.timestamp - stream.startTime;
            recipientBalance =
                ((stream.depositedShares * timeDelta) /
                    (stream.endTime - stream.startTime)) -
                uint256(stream.withdrawnShares);
            senderBalance = uint256(stream.depositedShares) - recipientBalance;
        }
    }

    function updateSender(uint256 streamId, address sender) external override {
        Stream storage stream = streams[streamId];
        if (sender == address(0)) revert InvalidAddressZero();
        if (stream.sender == address(0)) revert InvalidStream();
        if (msg.sender != stream.sender) revert NotSender();
        stream.sender = sender;
    }

    function whitelistReceiver(ISwapReceiver receiver, bool approved)
        external
        onlyOwner
    {
        whitelistedReceivers[receiver] = approved;
        emit LogWhitelistReceiver(receiver, approved);
    }

    function _depositToken(
        address token,
        address from,
        address to,
        uint256 amount,
        bool fromBentoBox
    ) internal returns (uint256 depositedShares) {
        if (token == wETH && address(this).balance >= amount) {
            (, depositedShares) = bentoBox.deposit{value: amount}(
                address(0),
                from,
                to,
                amount,
                0
            );
        } else {
            if (fromBentoBox) {
                depositedShares = bentoBox.toShare(token, amount, false);
                bentoBox.transfer(token, from, to, depositedShares);
            } else {
                (, depositedShares) = bentoBox.deposit(
                    token,
                    from,
                    to,
                    amount,
                    0
                );
            }
        }
    }

    function _transferToken(
        address token,
        address from,
        address to,
        uint256 amount,
        bool toBentoBox
    ) internal {
        if (toBentoBox) {
            bentoBox.transfer(token, from, to, amount);
        } else {
            bentoBox.withdraw(token, from, to, 0, amount);
        }
    }
}
