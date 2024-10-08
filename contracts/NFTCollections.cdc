import "NonFungibleToken"
import "Burner"

access(all) contract NFTCollections {

    access(all) let version: UInt32
    access(all) let NFT_COLLECTION_MANAGER_PATH: StoragePath

    access(all) event ContractInitialized()
    access(all) event Withdraw(address: Address, id: UInt64)
    access(all) event Deposit(address: Address, id: UInt64)

    access(all) entitlement Owner

    init() {
        self.version = 1
        self.NFT_COLLECTION_MANAGER_PATH = /storage/NFTCollectionManager
        emit ContractInitialized()
    }

    access(all) fun getVersion(): UInt32 {
        return self.version
    }

    access(all) resource interface WrappedNFT {
        access(all) fun getContractName(): String
        access(all) fun getAddress(): Address
        access(all) fun getCollectionPath(): PublicPath
        access(all) fun borrowNFT(): &{NonFungibleToken.NFT}
    }

    access(all) resource interface Provider {
        access(Owner) fun withdraw(address: Address, withdrawID: UInt64): @{NonFungibleToken.NFT}?
        access(Owner) fun withdrawWrapper(address: Address, withdrawID: UInt64): @NFTWrapper?
        access(Owner) fun batchWithdraw(address: Address, batch: [UInt64], into: &{NonFungibleToken.Collection})
        access(Owner) fun batchWithdrawWrappers(address: Address, batch: [UInt64]): @Collection?
        access(all) fun borrowWrapper(address: Address, id: UInt64): &NFTWrapper?
        access(all) fun borrowNFT(address: Address, id: UInt64): &{NonFungibleToken.NFT}?
    }

    access(all) resource interface Receiver {
        access(all) fun deposit(contractName: String, address: Address, collectionPath: PublicPath, token: @{NonFungibleToken.NFT})
        access(all) fun depositWrapper(wrapper: @NFTWrapper)
        access(all) fun batchDeposit(contractName: String, address: Address, collectionPath: PublicPath, batch: @{NonFungibleToken.Collection})
        access(all) fun batchDepositWrapper(batch: @Collection)
    }

    access(all) resource interface CollectionPublic {
        access(all) fun borrowWrapper(address: Address, id: UInt64): &NFTWrapper?
        access(all) fun borrowNFT(address: Address, id: UInt64): &{NonFungibleToken.NFT}?

        access(all) fun deposit(contractName: String, address: Address, collectionPath: PublicPath, token: @{NonFungibleToken.NFT})
        access(all) fun depositWrapper(wrapper: @NFTWrapper)
        access(all) fun batchDeposit(contractName: String, address: Address, collectionPath: PublicPath, batch: @{NonFungibleToken.Collection})
        access(all) fun batchDepositWrapper(batch: @Collection)

        access(all) fun getIDs(): {Address:[UInt64]}
    }

    // A resource for managing collections of NFTs
    //
    access(all) resource NFTCollectionManager {

        access(self) let collections: @{String: Collection}

        init() {
            self.collections <- {}
        }

        access(all) fun getCollectionNames(): [String] {
            return self.collections.keys
        }

        access(all) fun createOrBorrowCollection(_ namespace: String): &Collection? {
            if self.collections[namespace] == nil {
                return self.createCollection(namespace)
            } else {
                return self.borrowCollection(namespace)
            }
        }

        access(all) fun createCollection(_ namespace: String): &Collection? {
            pre {
                self.collections[namespace] == nil: "Collection with that namespace already exists"
            }
            let alwaysEmpty <- self.collections[namespace] <- create Collection()
            destroy alwaysEmpty
            return &self.collections[namespace]
        }

        access(all) fun borrowCollection(_ namespace: String): &Collection? {
            pre {
                self.collections[namespace] != nil: "Collection with that namespace not found"
            }
            return &self.collections[namespace]
        }
    }

    // Creates and returns a new NFTCollectionManager resource for managing many
    // different Collections
    //
    access(all) fun createNewNFTCollectionManager(): @NFTCollectionManager {
        return <- create NFTCollectionManager()
    }

    // An NFT wrapped with useful information
    //
    access(all) resource NFTWrapper : WrappedNFT {
        access(self) let contractName: String
        access(self) let address: Address
        access(self) let collectionPath: PublicPath
        access(self) var nft: @{NonFungibleToken.NFT}?

        init(
            contractName: String,
            address: Address,
            collectionPath: PublicPath,
            token: @{NonFungibleToken.NFT}
        ) {
            self.contractName = contractName
            self.address = address
            self.collectionPath = collectionPath
            self.nft <- token
        }

        access(all) fun getContractName(): String {
            return self.contractName
        }

        access(all) fun getAddress(): Address {
            return self.address
        }

        access(all) fun getCollectionPath(): PublicPath {
            return self.collectionPath
        }

        access(all) fun borrowNFT(): &{NonFungibleToken.NFT} {
            pre {
                self.nft != nil: "Wrapped NFT is nil"
            }

            let ref: &{NonFungibleToken.NFT}? = &self.nft
            assert(ref != nil, message: "nft is nil")

            return ref!
        }

        access(contract) fun unwrapNFT(): @{NonFungibleToken.NFT} {
            pre {
                self.nft != nil: "Wrapped NFT is nil"
            }
            let optionalNft <- self.nft <- nil
            let nft <- optionalNft!
            return <- nft
        }

        access(contract) fun burnCallback() {
            assert(self.nft == nil, message: "Wrapped NFT is not nil")
        }
    }

    access(all) resource Collection : CollectionPublic, Provider, Receiver {

        access(self) var collections: @{Address: ShardedNFTWrapperCollection}

        init() {
            self.collections <- {}
        }

        access(all) fun deposit(contractName: String, address: Address, collectionPath: PublicPath, token: @{NonFungibleToken.NFT}) {
            let wrapper <- create NFTWrapper(
                contractName: contractName,
                address: address,
                collectionPath: collectionPath,
                token: <- token
            )

            if self.collections[address] == nil {
                self.collections[address] <-! NFTCollections.createEmptyShardedNFTWrapperCollection()
            }

            let collection <- self.collections.remove(key: address)!
            collection.deposit(wrapper: <- wrapper)
            self.collections[address] <-! collection
        }

        access(all) fun depositWrapper(wrapper: @NFTWrapper) {
            let address = wrapper.getAddress()
            if self.collections[address] == nil {
                self.collections[address] <-! NFTCollections.createEmptyShardedNFTWrapperCollection()
            }

            let collection <- self.collections.remove(key: address)!
            collection.deposit(wrapper: <- wrapper)
            self.collections[address] <-! collection
        }

        access(all) fun batchDeposit(contractName: String, address: Address, collectionPath: PublicPath, batch: @{NonFungibleToken.Collection}) {
            let keys = batch.getIDs()
            for key in keys {
                self.deposit(
                    contractName: contractName,
                    address: address,
                    collectionPath: collectionPath,
                    token: <- batch.withdraw(withdrawID: key)
                )
            }
            destroy batch
        }

        access(all) fun batchDepositWrapper(batch: @Collection) {
            var addressMap = batch.getIDs()
            for address in addressMap.keys {
                let ids = addressMap[address] ?? []
                for id in ids {
                    self.depositWrapper(
                        wrapper: <- batch.withdrawWrapper(
                            address: address,
                            withdrawID: id
                        )
                    )
                }
            }
            destroy batch
        }

        access(Owner) fun withdraw(address: Address, withdrawID: UInt64): @{NonFungibleToken.NFT} {
            if self.collections[address] == nil {
                panic("No NFT with that Address exists")
            }

            let collection <- self.collections.remove(key: address)!
            let wrapper <- collection.withdraw(withdrawID: withdrawID)
            self.collections[address] <-! collection
            let nft <- wrapper.unwrapNFT()
            destroy wrapper
            return <- nft
        }

        access(Owner) fun withdrawWrapper(address: Address, withdrawID: UInt64): @NFTWrapper {
            if self.collections[address] == nil {
                panic("No NFT with that Address exists")
            }

            let collection <- self.collections.remove(key: address)!
            let wrapper <- collection.withdraw(withdrawID: withdrawID)
            self.collections[address] <-! collection
            return <- wrapper
        }

        access(Owner) fun batchWithdraw(address: Address, batch: [UInt64], into: &{NonFungibleToken.Collection}) {
            for id in batch {
                let nft <- self.withdraw(address: address,withdrawID: id)
                into.deposit(token: <- nft)
            }
        }

        access(Owner) fun batchWithdrawWrappers(address: Address, batch: [UInt64]): @Collection {
            var into <- NFTCollections.createEmptyCollection()
            for id in batch {
                into.depositWrapper(
                    wrapper: <- self.withdrawWrapper(
                        address: address,
                        withdrawID: id
                    )
                )
            }
            return <- into
        }

        access(all) fun getIDs(): {Address:[UInt64]} {
            var ids: {Address:[UInt64]} = {}
            for key in self.collections.keys {
                ids[key] = []
                for id in self.collections[key]?.getIDs() ?? [] {
                    ids[key]!.append(id)
                }
            }
            return ids
        }

        access(all) fun borrowNFT(address: Address, id: UInt64): &{NonFungibleToken.NFT} {
            return self.borrowWrapper(address: address, id: id)!.borrowNFT()
        }

        access(all) fun borrowWrapper(address: Address, id: UInt64): &NFTWrapper? {
            if self.collections[address] == nil {
                panic("No NFT with that Address exists")
            }
            let collection = &self.collections[address] as &ShardedNFTWrapperCollection?
            if collection == nil {
                return nil
            }
            return collection!.borrowWrapper(id: id)
        }

        access(contract) fun burnCallback() {
            let keys = self.collections.keys
            for k in keys {
                let collection: @NFTCollections.ShardedNFTWrapperCollection <- self.collections.remove(key: k)!
                Burner.burn(<-collection)
            }
        }
    }

    access(all) fun createEmptyCollection(): @Collection {
        return <- create NFTCollections.Collection()
    }

    access(all) resource ShardedNFTWrapperCollection {

        access(self) var collections: @{UInt64: NFTWrapperCollection}
        access(self) let numBuckets: UInt64

        init(_ numBuckets: UInt64) {
            self.collections <- {}
            self.numBuckets = numBuckets
            var i: UInt64 = 0
            while i < numBuckets {
                self.collections[i] <-! NFTCollections.createEmptyNFTWrapperCollection() as! @NFTWrapperCollection
                i = i + UInt64(1)
            }
        }

        access(all) fun deposit(wrapper: @NFTWrapper) {
            let bucket = wrapper.borrowNFT().id % self.numBuckets
            let collection <- self.collections.remove(key: bucket)!
            collection.deposit(wrapper: <-wrapper)
            self.collections[bucket] <-! collection
        }

        access(all) fun batchDeposit(batch: @ShardedNFTWrapperCollection) {
            let keys = batch.getIDs()
            for key in keys {
                self.deposit(wrapper: <- batch.withdraw(withdrawID: key))
            }
            destroy batch
        }

        access(Owner) fun withdraw(withdrawID: UInt64): @NFTWrapper {
            let bucket = withdrawID % self.numBuckets
            let wrapper <- self.collections[bucket]?.withdraw(withdrawID: withdrawID)!
            return <-wrapper
        }

        access(Owner) fun batchWithdraw(batch: [UInt64]): @ShardedNFTWrapperCollection {
            var batchCollection <- NFTCollections.createEmptyShardedNFTWrapperCollection()
            for id in batch {
                batchCollection.deposit(wrapper: <-self.withdraw(withdrawID: id))
            }
            return <- batchCollection
        }

        access(all) fun getIDs(): [UInt64] {
            var ids: [UInt64] = []
            for key in self.collections.keys {
                for id in self.collections[key]?.getIDs() ?? [] {
                    ids.append(id)
                }
            }
            return ids
        }

        access(all) fun borrowWrapper(id: UInt64): &NFTWrapper? {
            let bucket = id % self.numBuckets
            let collection = &self.collections[bucket] as &NFTWrapperCollection?
            if collection == nil {
                return nil
            }
            return collection!.borrowWrapper(id: id)
        }

        access(contract) fun burnCallback() {
            let keys = self.collections.keys
            for k in keys {
                let collection: @NFTCollections.NFTWrapperCollection <- self.collections.remove(key: k)!
                Burner.burn(<-collection)
            }
        }
    }

    access(all) fun createEmptyShardedNFTWrapperCollection(): @ShardedNFTWrapperCollection {
        return <- create NFTCollections.ShardedNFTWrapperCollection(32)
    }

    // A collection of NFTWrappers
    //
    access(all) resource NFTWrapperCollection {

        access(self) var wrappers: @{UInt64: NFTWrapper}

        init() {
            self.wrappers <- {}
        }

        access(all) fun deposit(wrapper: @NFTWrapper) {
            let address = wrapper.getAddress()
            let id = wrapper.borrowNFT().id
            let oldWrapper <- self.wrappers[id] <- wrapper
            if oldWrapper != nil {
                panic("This Collection already has an NFTWrapper with that id")
            }
            emit Deposit(address: address, id: id)
            destroy oldWrapper
        }

        access(all) fun batchDeposit(batch: @NFTWrapperCollection) {
            let keys = batch.getIDs()
            for key in keys {
                self.deposit(wrapper: <-batch.withdraw(withdrawID: key))
            }
            destroy batch
        }

        access(Owner) fun withdraw(withdrawID: UInt64): @NFTWrapper {
            let wrapper <- self.wrappers.remove(key: withdrawID)
                ?? panic("Cannot withdraw: NFTWrapper does not exist in the collection")
            emit Withdraw(address: wrapper.getAddress(), id: withdrawID)
            return <- wrapper
        }

        access(Owner) fun batchWithdraw(batch: [UInt64]): @NFTWrapperCollection {
            var batchCollection <- create NFTWrapperCollection()
            for id in batch {
                batchCollection.deposit(wrapper: <-self.withdraw(withdrawID: id))
            }
            return <- batchCollection
        }

        access(all) fun getIDs(): [UInt64] {
            return self.wrappers.keys
        }

        access(all) fun borrowWrapper(id: UInt64): &NFTWrapper? {
            return &self.wrappers[id] as &NFTWrapper?
        }

        access(contract) fun burnCallback() {
            let keys = self.wrappers.keys
            for k in keys {
                let wrapper: @NFTCollections.NFTWrapper <- self.wrappers.remove(key: k)!
                Burner.burn(<-wrapper)
            }
        }
    }

    access(all) fun createEmptyNFTWrapperCollection(): @NFTWrapperCollection {
        return <- create NFTCollections.NFTWrapperCollection()
    }
}
