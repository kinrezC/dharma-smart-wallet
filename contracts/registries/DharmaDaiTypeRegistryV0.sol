pragma solidity ^0.5.11;

import "@openzeppelin/contracts/cryptography/ECDSA.sol";
import "../../interfaces/DharmaDaiTypeRegistryInterface.sol";

/**
 * @title DharmaMcdRegistryV0
 * @author Kinrezc
 * @notice The DharmaMcdRegistry is an upgradeable contract that
 * holds data about whether or not a smart wallet has opted into
 * using dai (dai v2 minted from MCD) as opposed to sai (dai v1 minted from
 * SCD ether collateralization).
 */


contract DharmaDaiTypeRegistryV0 is
  DharmaDaiTypeRegistryInterface {

  // Mapping of contract wallet addresses to dai asset type in slot 0
  mapping (address => MakerDaiAssetType) daiType;

  function setAssetTypeDai(address smartWallet) external returns (bool success) {
    if (msg.sender != smartWallet) {
      success = false;
    } else {
      if (daiType[smartWallet] == MakerDaiAssetType.DAI) {
        success = true;
      } else {
        daiType[smartWallet] = MakerDaiAssetType.DAI;
        success = true;
      }
    }
  }

  function setAssetTypeSai(address smartWallet) external returns (bool success) {
    if (msg.sender != smartWallet) {
      success = false;
    } else {
      if (daiType[smartWallet] == MakerDaiAssetType.SAI) {
        success = true;
      } else {
        daiType[smartWallet] = MakerDaiAssetType.SAI;
        success = true;
      }
    }
  }

}