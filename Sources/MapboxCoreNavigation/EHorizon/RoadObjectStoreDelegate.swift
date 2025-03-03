import Foundation

/** `RoadObjectStore` delegate */
public protocol RoadObjectStoreDelegate: AnyObject {
    /// This method is called when a road object with the given identifier has been added to the road objects store.
    func didAddRoadObject(identifier: RoadObject.Identifier)
    
    /// This method is called when a road object with the given identifier has been updated in the road objects store.
    func didUpdateRoadObject(identifier: RoadObject.Identifier)
    
    /// This method is called when a road object with the given identifier has been removed from the road objects store.
    func didRemoveRoadObject(identifier: RoadObject.Identifier)
}
