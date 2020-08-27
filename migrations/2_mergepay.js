const MergeCoin = artifacts.require("MergeCoin");
const MergePay = artifacts.require("MergePay");

module.exports = function (deployer) {
  deployer.deploy(MergeCoin).then(() => deployer.deploy(MergePay, MergeCoin.address));
};
