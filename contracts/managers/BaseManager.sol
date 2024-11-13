// Base pattern for all managers
contract ManagerBase {
    bool private _initialized;
    
    modifier initializer() {
        require(!_initialized, "Already initialized");
        _;
        _initialized = true;
    }
}