pragma solidity ^0.5.11;


interface ScdMcdMigrationInterface {
    function swapSaiToDai(
      uint wad
    ) external;

    function swapSaiToDAi(
      uint wad
    ) external;

    function migrate(
      bytes32 cup
    ) external;
}