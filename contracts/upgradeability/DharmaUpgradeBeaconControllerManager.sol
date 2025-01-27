pragma solidity 0.5.11;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../helpers/TwoStepOwnable.sol";
import "../helpers/Timelocker.sol";
import "../../interfaces/UpgradeBeaconControllerInterface.sol";
import "../../interfaces/DharmaUpgradeBeaconControllerManagerInterface.sol";
import "../../interfaces/TimelockerModifiersInterface.sol";


/**
 * @title DharmaUpgradeBeaconControllerManager
 * @author 0age
 * @notice This contract will be owned by DharmaUpgradeMultisig and will manage
 * upgrades to the global smart wallet and key ring implementation contracts via
 * dedicated control over the "upgrade beacon" controller contracts (and can
 * additionally be used to manage other upgrade beacon controllers). It contains
 * a set of timelocked functions, where the `setTimelock` function must first be
 * called, with the same arguments that the function will be supplied with.
 * Then, a given time interval must first fully transpire before the timelock
 * functions can be successfully called.
 *
 * The timelocked functions currently implemented include:
 *  upgrade(address controller, address implementation)
 *  transferControllerOwnership(address controller, address newOwner)
 *  modifyTimelockInterval(bytes4 functionSelector, uint256 newTimelockInterval)
 *  modifyTimelockExpiration(
 *    bytes4 functionSelector, uint256 newTimelockExpiration
 *  )
 *
 * It also specifies dedicated implementations for the Dharma Smart Wallet and
 * Dharma Key Ring upgrade beacons that can be triggered in an emergency or in
 * the event of an extended period of inactivity from Dharma. These contingency
 * implementations give the user the ability to withdraw any funds on their
 * smart wallet by submitting a transaction directly from the account of any of
 * their signing keys, but are otherwise kept as simple as possible.
 *
 * This contract can transfer ownership of any upgrade beacon controller it owns
 * (subject to the timelock on `transferControllerOwnership`), in order to
 * introduce new upgrade conditions or to otherwise alter the way that upgrades
 * are carried out.
 */
contract DharmaUpgradeBeaconControllerManager is
  DharmaUpgradeBeaconControllerManagerInterface,
  TimelockerModifiersInterface,
  TwoStepOwnable,
  Timelocker {
  using SafeMath for uint256;

  // Store the last implementation address for each controller + beacon pair.
  mapping(address => mapping (address => address)) private _lastImplementation;

  // Store information on contingency status of each controller + beacon pair.
  mapping(address => mapping (address => AdharmaContingency)) private _adharma;

  // New controller owners must accept ownership before a transfer can occur.
  mapping(address => mapping(address => bool)) private _willAcceptOwnership;

  // Track the last heartbeat timestamp as well as the current heartbeat address
  uint256 private _lastHeartbeat;
  address private _heartbeater;

  // Store the address of the Dharma Smart Wallet Upgrade Beacon as a constant.
  address private constant _DHARMA_SMART_WALLET_UPGRADE_BEACON = address(
    0x000000000026750c571ce882B17016557279ADaa
  );

  // Store the Adharma Smart Wallet Contingency implementation. Note that this
  // is specific to the smart wallet and will not be activated on other beacons.
  address private constant _ADHARMA_SMART_WALLET_IMPLEMENTATION = address(
    0x0000000053d300f11703dcDD1e90921Db83F0048
  );

  // Store the address of the Dharma Key Ring Upgrade Beacon as a constant.
  address private constant _DHARMA_KEY_RING_UPGRADE_BEACON = address(
    0x0000000000BDA2152794ac8c76B2dc86cbA57cad
  );

  // Store the Adharma Key Ring Contingency implementation. Note that this is
  // specific to the key ring and will not be activated on other beacons.
  address private constant _ADHARMA_KEY_RING_IMPLEMENTATION = address(
    0x00000000480003d5eE4F51134CE73Cc9AC00f693
  );

  /**
   * @notice In the constructor, set tx.origin as initial owner, the initial
   * minimum timelock interval and expiration values, and some initial variable
   * values.
   */
  constructor() public {
    // Ensure Adharma Smart Wallet implementation has the correct runtime code.
    bytes32 adharmaSmartWalletHash;
    bytes32 expectedAdharmaSmartWalletHash = bytes32(
      0x2534c2b555b9011741eabee1c96e1683bb4f58483d05d3e654f00fde85c2673c
    );
    address adharmaSmartWallet = _ADHARMA_SMART_WALLET_IMPLEMENTATION;
    assembly { adharmaSmartWalletHash := extcodehash(adharmaSmartWallet) }
    require(
      adharmaSmartWalletHash == expectedAdharmaSmartWalletHash,
      "Adharma Smart Wallet implementation runtime code hash is incorrect."
    );

    // Ensure Adharma Key Ring implementation has the correct runtime code.
    bytes32 adharmaKeyRingHash;
    bytes32 expectedAdharmaKeyRingHash = bytes32(
      0x72f85d929335f00aee7e110513479e43febf22b0ee7826ee4f8cfc767be6c001
    );
    address adharmaKeyRing = _ADHARMA_KEY_RING_IMPLEMENTATION;
    assembly { adharmaKeyRingHash := extcodehash(adharmaKeyRing) }
    require(
      adharmaKeyRingHash == expectedAdharmaKeyRingHash,
      "Adharma Key Ring implementation runtime code hash is incorrect."
    );

    // Set initial minimum timelock interval values.
    _setInitialTimelockInterval(
      this.transferControllerOwnership.selector, 4 weeks
    );
    _setInitialTimelockInterval(this.modifyTimelockInterval.selector, 4 weeks);
    _setInitialTimelockInterval(
      this.modifyTimelockExpiration.selector, 4 weeks
    );
    _setInitialTimelockInterval(this.upgrade.selector, 7 days);

    // Set initial default timelock expiration values.
    _setInitialTimelockExpiration(
      this.transferControllerOwnership.selector, 7 days
    );
    _setInitialTimelockExpiration(this.modifyTimelockInterval.selector, 7 days);
    _setInitialTimelockExpiration(
      this.modifyTimelockExpiration.selector, 7 days
    );
    _setInitialTimelockExpiration(this.upgrade.selector, 7 days);

    // Set the initial owner as the initial heartbeater.
    _heartbeater = tx.origin;
    _lastHeartbeat = now;
  }

  /**
   * @notice Initiates a timelocked upgrade process via a given controller and
   * upgrade beacon to a given implementation address. Only the owner may call
   * this function. Once the timelock period is complete (and before it has
   * expired) the owner may call `upgrade` to complete the process and trigger
   * the upgrade.
   * @param controller address of controller to call into that will trigger the
   * update to the specified upgrade beacon.
   * @param beacon address of upgrade beacon to set the new implementation on.
   * @param implementation the address of the new implementation.
   * @param extraTime Additional time in seconds to add to the timelock.
   */
  function initiateUpgrade(
    address controller,
    address beacon,
    address implementation,
    uint256 extraTime
  ) external onlyOwner {
    require(controller != address(0), "Must specify a controller address.");

    require(beacon != address(0), "Must specify a beacon address.");

    // Ensure that the implementaton contract is not the null address.
    require(
      implementation != address(0),
      "Implementation cannot be the null address."
    );

    // Ensure that the implementation contract has code via extcodesize.
    uint256 size;
    assembly {
      size := extcodesize(implementation)
    }
    require(size > 0, "Implementation must have contract code.");

    // Set the timelock and emit a `TimelockInitiated` event.
    _setTimelock(
      this.upgrade.selector,
      abi.encode(controller, beacon, implementation),
      extraTime
    );
  }

  /**
   * @notice Timelocked function to set a new implementation address on an
   * upgrade beacon contract. This function could optionally check the
   * runtime code of the specified upgrade beacon, but that step is not strictly
   * necessary.
   * @param controller address of controller to call into that will trigger the
   * update to the specified upgrade beacon.
   * @param beacon address of upgrade beacon to set the new implementation on.
   * @param implementation the address of the new implementation.
   */
  function upgrade(
    address controller, address beacon, address implementation
  ) external onlyOwner {
    // Ensure that the timelock has been set and is completed.
    _enforceTimelock(abi.encode(controller, beacon, implementation));

    // Reset the heartbeat to the current time.
    _lastHeartbeat = now;

    // Call controller with beacon to upgrade and implementation to upgrade to.
    _upgrade(controller, beacon, implementation);
  }

  /**
   * @notice Allow a new potential owner of an upgrade beacon controller to
   * accept ownership of the controller.
   * @param controller address of controller to allow ownership transfer for.
   * @param willAcceptOwnership a boolean signifying if an ownership transfer to
   * the caller is acceptable.
   */
  function agreeToAcceptOwnership(
    address controller, bool willAcceptOwnership
  ) external {
    require(controller != address(0), "Must specify a controller address.");

    // Register whether or not the new owner is willing to accept ownership.
    _willAcceptOwnership[controller][msg.sender] = willAcceptOwnership;
  }

  /**
   * @notice Initiates a timelock to set a new owner on an upgrade beacon
   * controller that is owned by this contract.
   * @param controller address of controller to transfer ownership of.
   * @param newOwner address to assign ownership of the controller to.
   * @param extraTime Additional time in seconds to add to the timelock.
   */
  function initiateTransferControllerOwnership(
    address controller, address newOwner, uint256 extraTime
  ) external onlyOwner {
    require(controller != address(0), "No controller address provided.");

    require(newOwner != address(0), "No new owner address provided.");

    // Ensure that the new owner has confirmed that it can accept ownership.
    require(
      _willAcceptOwnership[controller][newOwner],
      "New owner must agree to accept ownership of the given controller."
    );

    // Set the timelock and emit a `TimelockInitiated` event.
    _setTimelock(
      this.transferControllerOwnership.selector,
      abi.encode(controller, newOwner),
      extraTime
    );
  }

  /**
   * @notice Timelocked function to set a new owner on an upgrade beacon
   * controller that is owned by this contract.
   * @param controller address of controller to transfer ownership of.
   * @param newOwner address to assign ownership of the controller to.
   */
  function transferControllerOwnership(
    address controller, address newOwner
  ) external onlyOwner {
    // Ensure that the new owner has confirmed that it can accept ownership.
    require(
      _willAcceptOwnership[controller][newOwner],
      "New owner must agree to accept ownership of the given controller."
    );

    // Ensure that the timelock has been set and is completed.
    _enforceTimelock(abi.encode(controller, newOwner));

    // Transfer ownership of the controller to the new owner.
    TwoStepOwnable(controller).transferOwnership(newOwner);
  }

  /**
   * @notice Send a new heartbeat. If 90 days pass without a heartbeat, anyone
   * may trigger the Adharma Contingency and force an upgrade to any controlled
   * upgrade beacon.
   */
  function heartbeat() external {
    require(msg.sender == _heartbeater, "Must be called from the heartbeater.");
    _lastHeartbeat = now;
  }

  /**
   * @notice Set a new heartbeater.
   * @param heartbeater address to designate as the heartbeating address.
   */
  function newHeartbeater(address heartbeater) external onlyOwner {
    require(heartbeater != address(0), "Must specify a heartbeater address.");
    _heartbeater = heartbeater;
  }

  /**
   * @notice Arm the Adharma Contingency upgrade. This is required as an extra
   * safeguard against accidentally triggering the Adharma Contingency.
   * @param controller address of controller to arm.
   * @param beacon address of upgrade beacon to arm.
   * @param armed Boolean that signifies the desired armed status.
   */
  function armAdharmaContingency(
    address controller, address beacon, bool armed
  ) external {
    require(controller != address(0), "Must specify a controller address.");

    require(beacon != address(0), "Must specify a beacon address.");

    // Determine if 90 days have passed since the last heartbeat.
    (bool expired, ) = _heartbeatStatus();
    require(
      isOwner() || expired,
      "Only callable by the owner or after 90 days without a heartbeat."
    );

    // Arm (or disarm) the Adharma Contingency.
    _adharma[controller][beacon].armed = armed;
  }

  /**
   * @notice Trigger the Adharma Contingency upgrade. This requires that the
   * owner first call `armAdharmaContingency` and set `armed` to `true`. This is
   * only to be invoked in cases of a time-sensitive emergency, or if the owner
   * has become inactive for over 90 days.
   * @param controller address of controller to call into that will trigger the
   * update to the Adharma contingency implementation on the specified upgrade
   * beacon.
   * @param beacon address of upgrade beacon to set the Adharma contingency
   * implementation on.
   */
  function activateAdharmaContingency(
    address controller, address beacon
  ) external {
    // Determine if 90 days have passed since the last heartbeat.
    (bool expired, ) = _heartbeatStatus();
    require(
      isOwner() || expired,
      "Only callable by the owner or after 90 days without a heartbeat."
    );

    // Ensure that the Adharma Contingency has been armed.
    require(
      _adharma[controller][beacon].armed,
      "Adharma Contingency is not armed - are SURE you meant to call this?"
    );

    require(
      !_adharma[controller][beacon].activated,
      "Adharma Contingency is already activated on this controller + beacon."
    );

    // Mark the Adharma Contingency as having been activated.
    _adharma[controller][beacon] = AdharmaContingency({
      armed: false,
      activated: true,
      activationTime: now
    });

    // Trigger the upgrade to the correct Adharma implementation contract.
    if (beacon == _DHARMA_SMART_WALLET_UPGRADE_BEACON) {
      _upgrade(controller, beacon, _ADHARMA_SMART_WALLET_IMPLEMENTATION);
    } else if (beacon == _DHARMA_KEY_RING_UPGRADE_BEACON) {
      _upgrade(controller, beacon, _ADHARMA_KEY_RING_IMPLEMENTATION);
    } else {
      revert("Only the smart wallet or key ring contingency can be activated.");
    }

    // Emit an event to signal that the Adharma Contingency has been activated.
    emit AdharmaContingencyActivated(controller, beacon);
  }

  /**
   * @notice Roll back an upgrade to the last implementation and exit from
   * contingency status if one currently exists. Note that you can also roll
   * back a rollback to restore it back to the original implementation that was
   * just rolled back from.
   * @param controller address of controller to call into that will trigger the
   * rollback on the specified upgrade beacon.
   * @param beacon address of upgrade beacon to roll back to the last
   * implementation.
   */
  function rollback(address controller, address beacon) external onlyOwner {
    // Ensure that there is an implementation address to roll back to.
    require(
      _lastImplementation[controller][beacon] != address(0),
      "No prior implementation to roll back to."
    );

    // Exit the contingency state if there is currently one active.
    if (_adharma[controller][beacon].activated) {
      delete _adharma[controller][beacon];

      emit AdharmaContingencyExited(controller, beacon);
    }

    // Reset the heartbeat to the current time.
    _lastHeartbeat = now;

    // Upgrade to the last implementation contract.
    _upgrade(controller, beacon, _lastImplementation[controller][beacon]);
  }

  /**
   * @notice Exit the Adharma Contingency by upgrading to a new contract. This
   * requires that the contingency is currently activated and that at least 48
   * hours has elapsed since it was activated.
   * @param controller address of controller to call into that will trigger the
   * update to the Adharma contingency implementation on the specified upgrade
   * beacon.
   * @param beacon address of upgrade beacon to set the Adharma contingency
   * implementation on.
   * @param implementation the address of the new implementation.
   */
  function exitAdharmaContingency(
    address controller, address beacon, address implementation
  ) external onlyOwner {
    // Ensure that the Adharma Contingency is currently active.
    require(
      _adharma[controller][beacon].activated,
      "Adharma Contingency is not currently activated."
    );

    // Ensure that at least 48 hours has elapsed since the contingency commenced.
    require(
      now > _adharma[controller][beacon].activationTime + 48 hours,
      "Cannot exit contingency with a new upgrade until 48 hours have elapsed."
    );

    // Exit the contingency state.
    delete _adharma[controller][beacon];

    // Reset the heartbeat to the current time.
    _lastHeartbeat = now;

    // Call controller with beacon to upgrade and implementation to upgrade to.
    _upgrade(controller, beacon, implementation);

    // Emit an event to signal that the Adharma Contingency has been activated.
    emit AdharmaContingencyExited(controller, beacon);
  }

  /**
   * @notice Sets the timelock for a new timelock interval for a given function
   * selector. Only the owner may call this function.
   * @param functionSelector the selector of the function to set the timelock
   * interval for.
   * @param newTimelockInterval The new timelock interval to set for the given
   * function selector.
   * @param extraTime Additional time in seconds to add to the timelock.
   */
  function initiateModifyTimelockInterval(
    bytes4 functionSelector, uint256 newTimelockInterval, uint256 extraTime
  ) external onlyOwner {
    // Ensure that a function selector is specified (no 0x00000000 selector).
    require(
      functionSelector != bytes4(0),
      "Function selector cannot be empty."
    );

    // Ensure a timelock interval over eight weeks is not set on this function.
    if (functionSelector == this.modifyTimelockInterval.selector) {
      require(
        newTimelockInterval <= 8 weeks,
        "Timelock interval of modifyTimelockInterval cannot exceed eight weeks."
      );
    }

    // Set the timelock and emit a `TimelockInitiated` event.
    _setTimelock(
      this.modifyTimelockInterval.selector,
      abi.encode(functionSelector, newTimelockInterval),
      extraTime
    );
  }

  /**
   * @notice Sets a new timelock interval for a given function selector. The
   * default for this function may also be modified, but has a maximum allowable
   * value of eight weeks. Only the owner may call this function.
   * @param functionSelector the selector of the function to set the timelock
   * interval for.
   * @param newTimelockInterval The new timelock interval to set for the given
   * function selector.
   */
  function modifyTimelockInterval(
    bytes4 functionSelector, uint256 newTimelockInterval
  ) external onlyOwner {
    // Ensure that a function selector is specified (no 0x00000000 selector).
    require(
      functionSelector != bytes4(0),
      "Function selector cannot be empty."
    );

    // Continue via logic in the inherited `_modifyTimelockInterval` function.
    _modifyTimelockInterval(functionSelector, newTimelockInterval);
  }

  /**
   * @notice Sets a new timelock expiration for a given function selector. The
   * default Only the owner may call this function. New expiration durations may
   * not exceed one month.
   * @param functionSelector the selector of the function to set the timelock
   * expiration for.
   * @param newTimelockExpiration The new timelock expiration to set for the
   * given function selector.
   * @param extraTime Additional time in seconds to add to the timelock.
   */
  function initiateModifyTimelockExpiration(
    bytes4 functionSelector, uint256 newTimelockExpiration, uint256 extraTime
  ) external onlyOwner {
    // Ensure that a function selector is specified (no 0x00000000 selector).
    require(
      functionSelector != bytes4(0),
      "Function selector cannot be empty."
    );

    // Ensure that the supplied default expiration does not exceed 1 month.
    require(
      newTimelockExpiration <= 30 days,
      "New timelock expiration cannot exceed one month."
    );

    // Ensure a timelock expiration under one hour is not set on this function.
    if (functionSelector == this.modifyTimelockExpiration.selector) {
      require(
        newTimelockExpiration >= 60 minutes,
        "Expiration of modifyTimelockExpiration must be at least an hour long."
      );
    }

    // Set the timelock and emit a `TimelockInitiated` event.
    _setTimelock(
      this.modifyTimelockExpiration.selector,
      abi.encode(functionSelector, newTimelockExpiration),
      extraTime
    );
  }

  /**
   * @notice Sets a new timelock expiration for a given function selector. The
   * default for this function may also be modified, but has a minimum allowable
   * value of one hour. Only the owner may call this function.
   * @param functionSelector the selector of the function to set the timelock
   * expiration for.
   * @param newTimelockExpiration The new timelock expiration to set for the
   * given function selector.
   */
  function modifyTimelockExpiration(
    bytes4 functionSelector, uint256 newTimelockExpiration
  ) external onlyOwner {
    // Ensure that a function selector is specified (no 0x00000000 selector).
    require(
      functionSelector != bytes4(0),
      "Function selector cannot be empty."
    );

    // Continue via logic in the inherited `_modifyTimelockExpiration` function.
    _modifyTimelockExpiration(
      functionSelector, newTimelockExpiration
    );
  }

  /**
   * @notice Determine if the deadman's switch has expired and get the time at
   * which it is set to expire (i.e. 90 days from the last heartbeat).
   */
  function heartbeatStatus() external view returns (
    bool expired, uint256 expirationTime
  ) {
    (expired, expirationTime) = _heartbeatStatus();
  }

  /**
   * @notice Internal view function to determine if the deadman's switch has
   * expired and to get the time at which it is set to expire (i.e. 90 days from
   * the last heartbeat).
   */
  function _heartbeatStatus() internal view returns (
    bool expired, uint256 expirationTime
  ) {
    expirationTime = _lastHeartbeat + 90 days;
    expired = now > expirationTime;
  }

  /**
   * @notice Private function that sets a new implementation address on an
   * upgrade beacon contract.
   * @param controller address of controller to call into that will trigger the
   * update to the specified upgrade beacon.
   * @param beacon address of upgrade beacon to set the new implementation on.
   * @param implementation the address of the new implementation.
   */
  function _upgrade(
    address controller, address beacon, address implementation
  ) private {
    // Ensure that the implementaton contract is not the null address.
    require(
      implementation != address(0),
      "Implementation cannot be the null address."
    );

    // Ensure that the implementation contract has code via extcodesize.
    uint256 size;
    assembly {
      size := extcodesize(implementation)
    }
    require(size > 0, "Implementation must have contract code.");

    // Try to get current implementation contract, defaulting to null address.
    address currentImplementation;
    (bool ok, bytes memory returnData) = beacon.call("");
    if (ok && returnData.length == 32) {
      currentImplementation = abi.decode(returnData, (address));
    } else {
      currentImplementation = address(0);
    }

    // Record the last implementation in case it needs to be restored.
    _lastImplementation[controller][beacon] = currentImplementation;

    // Trigger the upgrade to the new implementation contract.
    UpgradeBeaconControllerInterface(controller).upgrade(
      beacon, implementation
    );
  }
}