// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

// @dev Allocation represents a single allocation for an IBC fungible token transfer.
struct ICS20Allocation {
    string sourcePort;
    string sourceChannel;
    Coin[] spendLimit;
    string[] allowList;
    string[] allowedPacketData;
}

/// @dev Dec represents a fixed point decimal value. The value is stored as an integer, and the
/// precision is stored as a uint8. The value is multiplied by 10^precision to get the actual value.
struct Dec {
    uint256 value;
    uint8 precision;
}

/// @dev Coin is a struct that represents a token with a denomination and an amount.
struct Coin {
    string denom;
    uint256 amount;
}

/// @dev DecCoin is a struct that represents a token with a denomination, an amount and a precision.
struct DecCoin {
    string denom;
    uint256 amount;
    uint8 precision;
}

/// @dev PageResponse is a struct that represents a page response.
struct PageResponse {
    bytes nextKey;
    uint64 total;
}

/// @dev PageRequest is a struct that represents a page request.
struct PageRequest {
    bytes key;
    uint64 offset;
    uint64 limit;
    bool countTotal;
    bool reverse;
}

/// @dev Height is a monotonically increasing data type
/// that can be compared against another Height for the purposes of updating and
/// freezing clients
///
/// Normally the RevisionHeight is incremented at each height while keeping
/// RevisionNumber the same. However some consensus algorithms may choose to
/// reset the height in certain conditions e.g. hard forks, state-machine
/// breaking changes In these cases, the RevisionNumber is incremented so that
/// height continues to be monotonically increasing even as the RevisionHeight
/// gets reset
struct Height {
    // the revision that the client is currently on
    uint64 revisionNumber;
    // the height within the given revision
    uint64 revisionHeight;
}

/// @dev Defines the initial description to be used for creating
/// a validator.
struct Description {
    string moniker;
    string identity;
    string website;
    string securityContact;
    string details;
}

/// @dev Defines the initial commission rates to be used for creating
/// a validator.
struct CommissionRates {
    uint256 rate;
    uint256 maxRate;
    uint256 maxChangeRate;
}

/// @dev Defines commission parameters for a given validator.
struct Commission {
    CommissionRates commissionRates;
    uint256 updateTime;
}

/// @dev Represents a validator in the staking module.
struct Validator {
    string operatorAddress;
    string consensusPubkey;
    bool jailed;
    BondStatus status;
    uint256 tokens;
    uint256 delegatorShares; // TODO: decimal
    string description;
    int64 unbondingHeight;
    int64 unbondingTime;
    uint256 commission;
    uint256 minSelfDelegation;
}

/// @dev Represents the output of a Redelegations query.
struct RedelegationResponse {
    Redelegation redelegation;
    RedelegationEntryResponse[] entries;
}

/// @dev Represents a redelegation between a delegator and a validator.
struct Redelegation {
    string delegatorAddress;
    string validatorSrcAddress;
    string validatorDstAddress;
    RedelegationEntry[] entries;
}

/// @dev Represents a RedelegationEntryResponse for the Redelegations query.
struct RedelegationEntryResponse {
    RedelegationEntry redelegationEntry;
    uint256 balance;
}

/// @dev Represents a single Redelegation entry.
struct RedelegationEntry {
    int64 creationHeight;
    int64 completionTime;
    uint256 initialBalance;
    uint256 sharesDst; // TODO: decimal
}

/// @dev Represents the output of the Redelegation query.
struct RedelegationOutput {
    string delegatorAddress;
    string validatorSrcAddress;
    string validatorDstAddress;
    RedelegationEntry[] entries;
}

/// @dev Represents a single entry of an unbonding delegation.
struct UnbondingDelegationEntry {
    int64 creationHeight;
    int64 completionTime;
    uint256 initialBalance;
    uint256 balance;
    uint64 unbondingId;
    int64 unbondingOnHoldRefCount;
}

/// @dev Represents the output of the UnbondingDelegation query.
struct UnbondingDelegationOutput {
    string delegatorAddress;
    string validatorAddress;
    UnbondingDelegationEntry[] entries;
}

/// @dev The status of the validator.
enum BondStatus {
    Unspecified,
    Unbonded,
    Unbonding,
    Bonded
}

interface IStaking {
    /// @dev Defines a method for creating a new validator.
    /// @param description The initial description
    /// @param commissionRates The initial commissionRates
    /// @param minSelfDelegation The validator's self declared minimum self delegation
    /// @param validatorAddress The validator address
    /// @param pubkey The consensus public key of the validator
    /// @param value The amount of the coin to be self delegated to the validator
    /// @return success Whether or not the create validator was successful
    function createValidator(
        Description calldata description,
        CommissionRates calldata commissionRates,
        uint256 minSelfDelegation,
        address validatorAddress,
        string memory pubkey,
        uint256 value
    ) external returns (bool success);

    /// @dev Defines a method for edit a validator.
    /// @param description Description parameter to be updated. Use the string "[do-not-modify]"
    /// as the value of fields that should not be updated.
    /// @param commissionRate CommissionRate parameter to be updated.
    /// Use commissionRate = -1 to keep the current value and not update it.
    /// @param minSelfDelegation MinSelfDelegation parameter to be updated.
    /// Use minSelfDelegation = -1 to keep the current value and not update it.
    /// @return success Whether or not edit validator was successful.
    function editValidator(
        Description calldata description,
        address validatorAddress,
        int256 commissionRate,
        int256 minSelfDelegation
    ) external returns (bool success);

    /// @dev Defines a method for performing a delegation of coins from a delegator to a validator.
    /// @param delegatorAddress The address of the delegator
    /// @param validatorAddress The address of the validator
    /// @param amount The amount of the bond denomination to be delegated to the validator.
    /// This amount should use the bond denomination precision stored in the bank metadata.
    /// @return success Whether or not the delegate was successful
    function delegate(
        address delegatorAddress,
        string memory validatorAddress,
        uint256 amount
    ) external returns (bool success);

    /// @dev Defines a method for performing an undelegation from a delegate and a validator.
    /// @param delegatorAddress The address of the delegator
    /// @param validatorAddress The address of the validator
    /// @param amount The amount of the bond denomination to be undelegated from the validator.
    /// This amount should use the bond denomination precision stored in the bank metadata.
    /// @return completionTime The time when the undelegation is completed
    function undelegate(
        address delegatorAddress,
        string memory validatorAddress,
        uint256 amount
    ) external returns (int64 completionTime);

    /// @dev Defines a method for performing a redelegation
    /// of coins from a delegator and source validator to a destination validator.
    /// @param delegatorAddress The address of the delegator
    /// @param validatorSrcAddress The validator from which the redelegation is initiated
    /// @param validatorDstAddress The validator to which the redelegation is destined
    /// @param amount The amount of the bond denomination to be redelegated to the validator
    /// This amount should use the bond denomination precision stored in the bank metadata.
    /// @return completionTime The time when the redelegation is completed
    function redelegate(
        address delegatorAddress,
        string memory validatorSrcAddress,
        string memory validatorDstAddress,
        uint256 amount
    ) external returns (int64 completionTime);

    /// @dev Allows delegators to cancel the unbondingDelegation entry
    /// and to delegate back to a previous validator.
    /// @param delegatorAddress The address of the delegator
    /// @param validatorAddress The address of the validator
    /// @param amount The amount of the bond denomination
    /// This amount should use the bond denomination precision stored in the bank metadata.
    /// @param creationHeight The height at which the unbonding took place
    /// @return success Whether or not the unbonding delegation was cancelled
    function cancelUnbondingDelegation(
        address delegatorAddress,
        string memory validatorAddress,
        uint256 amount,
        uint256 creationHeight
    ) external returns (bool success);

    /// @dev Queries the given amount of the bond denomination to a validator.
    /// @param delegatorAddress The address of the delegator.
    /// @param validatorAddress The address of the validator.
    /// @return shares The amount of shares, that the delegator has received.
    /// @return balance The amount in Coin, that the delegator has delegated to the given validator.
    /// This returned balance uses the bond denomination precision stored in the bank metadata.
    function delegation(
        address delegatorAddress,
        string memory validatorAddress
    ) external view returns (uint256 shares, Coin memory balance);

    /// @dev Returns the delegation shares and coins, that are currently
    /// unbonding for a given delegator and validator pair.
    /// @param delegatorAddress The address of the delegator.
    /// @param validatorAddress The address of the validator.
    /// @return unbondingDelegation The delegations that are currently unbonding.
    function unbondingDelegation(
        address delegatorAddress,
        string memory validatorAddress
    ) external view returns (UnbondingDelegationOutput memory unbondingDelegation);

    /// @dev Queries validator info for a given validator address.
    /// @param validatorAddress The address of the validator.
    /// @return validator The validator info for the given validator address.
    function validator(address validatorAddress) external view returns (Validator memory validator);

    /// @dev Queries all validators that match the given status.
    /// @param status Enables to query for validators matching a given status.
    /// @param pageRequest Defines an optional pagination for the request.
    function validators(
        string memory status,
        PageRequest calldata pageRequest
    ) external view returns (Validator[] memory validators, PageResponse memory pageResponse);

    /// @dev Queries all redelegations from a source to a destination validator for a given delegator.
    /// @param delegatorAddress The address of the delegator.
    /// @param srcValidatorAddress Defines the validator address to redelegate from.
    /// @param dstValidatorAddress Defines the validator address to redelegate to.
    /// @return redelegation The active redelegations for the given delegator, source and destination
    /// validator combination.
    function redelegation(
        address delegatorAddress,
        string memory srcValidatorAddress,
        string memory dstValidatorAddress
    ) external view returns (RedelegationOutput memory redelegation);

    /// @dev Queries all redelegations based on the specified criteria:
    /// for a given delegator and/or origin validator address
    /// and/or destination validator address
    /// in a specified pagination manner.
    /// @param delegatorAddress The address of the delegator as string (can be a zero address).
    /// @param srcValidatorAddress Defines the validator address to redelegate from (can be empty string).
    /// @param dstValidatorAddress Defines the validator address to redelegate to (can be empty string).
    /// @param pageRequest Defines an optional pagination for the request.
    /// @return response Holds the redelegations for the given delegator, source and destination validator combination.
    function redelegations(
        address delegatorAddress,
        string memory srcValidatorAddress,
        string memory dstValidatorAddress,
        PageRequest calldata pageRequest
    ) external view returns (RedelegationResponse[] memory response, PageResponse memory pageResponse);
}

contract MockStaking is IStaking {
    Vm private vm;

    // Storage to track delegations: delegatorAddress => validatorAddress => delegation info
    mapping(address => mapping(string operatorAddress => DelegationInfo)) public delegations;

    // Storage to track unbonding delegations: delegatorAddress => validatorAddress => unbonding entries
    mapping(address => mapping(string => UnbondingDelegationEntry[])) public unbondingDelegations;

    // Storage to track validators: validatorAddress => validator info
    mapping(address => ValidatorInfo) public validatorsStorage;

    mapping(string operatorAddress => address validatorAddress) public operatorToValidator;

    // Array to track all validator addresses for enumeration
    address[] public validatorAddresses;

    // Counter for unbonding IDs
    uint64 private unbondingIdCounter;

    // Struct to store delegation information
    struct DelegationInfo {
        uint256 shares;
        uint256 balance;
        bool exists;
    }

    // Struct to store validator information
    struct ValidatorInfo {
        Description description;
        CommissionRates commissionRates;
        uint256 minSelfDelegation;
        string pubkey;
        uint256 totalDelegated;
        uint256 totalShares;
        bool exists;
        BondStatus status;
    }

    // Default token denomination for mock
    string public constant DEFAULT_DENOM = "stake";

    // Unbonding period in seconds (mock value)
    uint256 public constant UNBONDING_PERIOD = 21 days;

    constructor(Vm vm_) {
        vm = vm_;
    }

    function createValidator(
        Description calldata description,
        CommissionRates calldata commissionRates,
        uint256 minSelfDelegation,
        address validatorAddress,
        string memory pubkey, /// @dev For testing purpose and for simplicity, this value will be the same as the operator address
        uint256 value
    ) external returns (bool success) {
        require(!validatorsStorage[validatorAddress].exists, "Validator already exists");
        require(value >= minSelfDelegation, "Self delegation must be >= minSelfDelegation");

        // Create validator info
        ValidatorInfo storage validator = validatorsStorage[validatorAddress];
        validator.description = description;
        validator.commissionRates = commissionRates;
        validator.minSelfDelegation = minSelfDelegation;
        validator.pubkey = pubkey;
        validator.totalDelegated = value;
        validator.totalShares = value;
        validator.exists = true;
        validator.status = BondStatus.Bonded;

        // Add to validator addresses array
        validatorAddresses.push(validatorAddress);

        /// @dev For testing purpose and for simplicity, this value will be the same as the operator address
        string memory operatorAddress = pubkey;

        operatorToValidator[operatorAddress] = validatorAddress;

        // Create self-delegation
        DelegationInfo storage selfDelegation = delegations[validatorAddress][operatorAddress];
        selfDelegation.balance = value;
        selfDelegation.shares = value;
        selfDelegation.exists = true;

        return true;
    }

    function editValidator(
        Description calldata description,
        address validatorAddress,
        int256 commissionRate,
        int256 minSelfDelegation
    ) external returns (bool success) {
        /// @dev Not implemented
        return true;
    }

    function delegate(
        address delegatorAddress,
        string memory validatorAddress,
        uint256 amount
    ) external override returns (bool success) {
        uint256 delegatorBalance = delegatorAddress.balance;
        require(delegatorBalance >= amount, "Insufficient balance to delegate from delegator");

        /// @dev simulate update balance storage in TAC EVM
        vm.deal(delegatorAddress, delegatorBalance - amount);

        DelegationInfo storage delegation = delegations[delegatorAddress][validatorAddress];

        if (delegation.exists) {
            delegation.balance += amount;
            delegation.shares += amount;
        } else {
            delegation.balance = amount;
            delegation.shares = amount;
            delegation.exists = true;
        }

        address validatorAddr = operatorToValidator[validatorAddress];

        if (validatorsStorage[validatorAddr].exists) {
            ValidatorInfo storage validator = validatorsStorage[validatorAddr];
            validator.totalDelegated += amount;
            validator.totalShares += amount;
        }
        return true;
    }

    function undelegate(
        address delegatorAddress,
        string memory validatorAddress,
        uint256 amount
    ) external returns (int64 completionTime) {
        DelegationInfo storage delegation = delegations[delegatorAddress][validatorAddress];
        require(delegation.exists, "No delegation found");
        require(delegation.balance >= amount, "Insufficient delegation balance");

        delegation.balance -= amount;
        delegation.shares -= amount;

        if (delegation.balance == 0) {
            delegation.exists = false;
        }

        address validatorAddr = operatorToValidator[validatorAddress];

        if (validatorsStorage[validatorAddr].exists) {
            ValidatorInfo storage validator = validatorsStorage[validatorAddr];
            validator.totalDelegated -= amount;
            validator.totalShares -= amount;
        }

        int64 currentTime = int64(uint64(block.timestamp));
        int64 unbondingCompletionTime = currentTime + int64(uint64(UNBONDING_PERIOD));

        UnbondingDelegationEntry memory unbondingEntry = UnbondingDelegationEntry({
            creationHeight: int64(uint64(block.number)),
            completionTime: unbondingCompletionTime,
            initialBalance: amount,
            balance: amount,
            unbondingId: unbondingIdCounter++,
            unbondingOnHoldRefCount: 0
        });
        unbondingDelegations[delegatorAddress][validatorAddress].push(unbondingEntry);
        return unbondingCompletionTime;
    }

    function redelegate(
        address delegatorAddress,
        string memory validatorSrcAddress,
        string memory validatorDstAddress,
        uint256 amount
    ) external returns (int64 completionTime) {
        DelegationInfo storage srcDelegation = delegations[delegatorAddress][validatorSrcAddress];

        require(srcDelegation.exists, "No delegation found for source validator");
        require(srcDelegation.balance >= amount, "Insufficient delegation balance");

        srcDelegation.balance -= amount;
        srcDelegation.shares -= amount;

        if (srcDelegation.balance == 0) {
            srcDelegation.exists = false;
        }

        DelegationInfo storage dstDelegation = delegations[delegatorAddress][validatorDstAddress];

        if (dstDelegation.exists) {
            dstDelegation.balance += amount;
            dstDelegation.shares += amount;
        } else {
            dstDelegation.balance = amount;
            dstDelegation.shares = amount;
            dstDelegation.exists = true;
        }

        address srcValidatorAddr = operatorToValidator[validatorSrcAddress];
        address dstValidatorAddr = operatorToValidator[validatorDstAddress];

        if (validatorsStorage[srcValidatorAddr].exists) {
            ValidatorInfo storage srcValidator = validatorsStorage[srcValidatorAddr];
            srcValidator.totalDelegated -= amount;
            srcValidator.totalShares -= amount;
        }

        if (validatorsStorage[dstValidatorAddr].exists) {
            ValidatorInfo storage dstValidator = validatorsStorage[dstValidatorAddr];
            dstValidator.totalDelegated += amount;
            dstValidator.totalShares += amount;
        }

        return 0;
    }

    function cancelUnbondingDelegation(
        address delegatorAddress,
        string memory validatorAddress,
        uint256 amount,
        uint256 creationHeight
    ) external returns (bool success) {
        UnbondingDelegationEntry[] storage entries = unbondingDelegations[delegatorAddress][validatorAddress];
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].creationHeight == int64(uint64(creationHeight))) {
                require(entries[i].balance >= amount, "Insufficient unbonding balance");
                entries[i].balance -= amount;
                if (entries[i].balance == 0) {
                    if (i < entries.length - 1) {
                        entries[i] = entries[entries.length - 1];
                    }
                    entries.pop();
                }
                DelegationInfo storage delegation = delegations[delegatorAddress][validatorAddress];
                if (delegation.exists) {
                    delegation.balance += amount;
                    delegation.shares += amount;
                } else {
                    delegation.balance = amount;
                    delegation.shares = amount;
                    delegation.exists = true;
                }
                address validatorAddr = operatorToValidator[validatorAddress];

                if (validatorsStorage[validatorAddr].exists) {
                    ValidatorInfo storage validator = validatorsStorage[validatorAddr];
                    validator.totalDelegated += amount;
                    validator.totalShares += amount;
                }
                return true;
            }
        }
        revert("No unbonding delegation found with specified creation height");
    }

    function delegation(
        address delegatorAddress,
        string memory validatorAddress
    ) external view returns (uint256 shares, Coin memory balance) {
        DelegationInfo storage delegation = delegations[delegatorAddress][validatorAddress];

        if (delegation.exists) {
            return (delegation.shares, Coin(DEFAULT_DENOM, delegation.balance));
        } else {
            return (0, Coin(DEFAULT_DENOM, 0));
        }
    }

    function unbondingDelegation(
        address delegatorAddress,
        string memory validatorAddress
    ) external view returns (UnbondingDelegationOutput memory unbondingDelegation) {
        UnbondingDelegationEntry[] storage entries = unbondingDelegations[delegatorAddress][validatorAddress];

        /// @dev Notice! This is a mock implementation, real implementation should support fully bech32 convertion.
        string memory delegatorAddressStr = vm.toString(delegatorAddress);

        return
            UnbondingDelegationOutput({
                delegatorAddress: delegatorAddressStr,
                validatorAddress: validatorAddress,
                entries: entries
            });
    }

    function validator(address validatorAddress) external view returns (Validator memory validator) {
        ValidatorInfo storage validatorInfo = validatorsStorage[validatorAddress];

        if (!validatorInfo.exists) {
            return Validator("", "", false, BondStatus.Unbonded, 0, 0, "", 0, 0, 0, 0);
        }

        // Convert description to string (using moniker as the main identifier)
        string memory descriptionStr = validatorInfo.description.moniker;
        if (bytes(validatorInfo.description.identity).length > 0) {
            descriptionStr = string(abi.encodePacked(descriptionStr, " (", validatorInfo.description.identity, ")"));
        }

        return
            Validator({
                operatorAddress: validatorInfo.pubkey, /// @dev For testing purpose and for simplicity, this value will be the same as the operator address
                consensusPubkey: validatorInfo.pubkey,
                jailed: false,
                status: validatorInfo.status,
                tokens: validatorInfo.totalDelegated,
                delegatorShares: validatorInfo.totalShares,
                description: descriptionStr,
                unbondingHeight: 0,
                unbondingTime: 0,
                commission: validatorInfo.commissionRates.rate,
                minSelfDelegation: validatorInfo.minSelfDelegation
            });
    }

    function validators(
        string memory status,
        PageRequest calldata pageRequest
    ) external view returns (Validator[] memory validators, PageResponse memory pageResponse) {
        /// @dev Not implemented
        Validator[] memory validators = new Validator[](0);
        return (validators, PageResponse("", 0));
    }

    function redelegation(
        address delegatorAddress,
        string memory srcValidatorAddress,
        string memory dstValidatorAddress
    ) external view returns (RedelegationOutput memory redelegation) {
        /// @dev Not implemented
        return RedelegationOutput("", "", "", new RedelegationEntry[](0));
    }

    function redelegations(
        address delegatorAddress,
        string memory srcValidatorAddress,
        string memory dstValidatorAddress,
        PageRequest calldata pageRequest
    ) external view returns (RedelegationResponse[] memory response, PageResponse memory pageResponse) {
        /// @dev Not implemented
        RedelegationResponse[] memory emptyResponse = new RedelegationResponse[](0);
        return (emptyResponse, PageResponse("", 0));
    }

    /// @dev Simulation action out of staking contract - but possible in TAC EVM
    function evmMethodRemoveAllUnbondingDelegations(address delegatorAddress, string memory validatorAddress) external {
        delete unbondingDelegations[delegatorAddress][validatorAddress];
    }
}
