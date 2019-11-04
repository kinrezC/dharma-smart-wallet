pragma solidity ^0.5.11;

interface DharmaDaiTypeRegistryInterface {

  enum MakerDaiAssetType {
    SAI,
    DAI
  }

  function setAssetTypeDai(
    address smartWallet
  ) external returns(
    bool success
  );

  function setAssetTypeSai(
    address smartWallet
  ) external returns (
    bool success
  );

}