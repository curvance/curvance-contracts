# Fuse Reference

### Resources

* Contracts repo: [https://github.com/Rari-Capital/compound-protocol](https://github.com/Rari-Capital/compound-protocol)
* fuse-sdk: [https://github.com/Rari-Capital/rari-dApp/tree/master/src/fuse-sdk](https://github.com/Rari-Capital/rari-dApp/tree/master/src/fuse-sdk)
* Fuse App: [https://app.rari.capital/fuse](https://app.rari.capital/fuse)

### General Notes

* Fuse uses upgradeable contracts to manage their pools where `Unitroller` acts as the delegator contract and `Comptroller` is the implementation contract (refer to [contracts repo](https://github.com/Rari-Capital/compound-protocol/tree/master/contracts))
  * Unlike typical upgradable contracts, however, their implementation extracts the storage from `Comptroller` and keeps it in `ComptrollerStorage` instead

### Specific Notes

{% content-ref url="comptroller.sol.md" %}
[comptroller.sol.md](comptroller.sol.md)
{% endcontent-ref %}
