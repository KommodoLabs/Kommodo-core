pragma solidity ^0.8.20;

contract MockUniPool {
    uint160 public sqrtPriceX96 = 79228162514264337593543950336;

    uint128 collect0 = 0;
    uint128 collect1 = 0;

    function slot0() external view returns (
        uint160 _sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool
    ) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function positions(bytes32) external view returns (
        uint128, uint256, uint256, uint128, uint128
    ) {
        return (0, 0, 0, collect0, collect1);
    }

    function mint(
        address, int24, int24, uint128, bytes calldata
    ) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function burn(
        int24, int24, uint128
    ) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function collect(
        address, int24, int24, uint128, uint128
    ) external view returns (uint256, uint256) {
        return (collect0, collect1);
    }

    function set_collect(   
        uint128 a, uint128 b
    ) public   {
        collect0 = a;
        collect1 = b;
    }

}
