//
//  DTCollectionViewManager.swift
//  DTCollectionViewManager
//
//  Created by Denys Telezhkin on 23.08.15.
//  Copyright © 2015 Denys Telezhkin. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import UIKit
import DTModelStorage

/// Adopting this protocol will automatically inject manager property to your object, that lazily instantiates DTCollectionViewManager object.
/// Target is not required to be UICollectionViewController, and can be a regular UIViewController with UICollectionView, or even different object like UICollectionViewCell.
public protocol DTCollectionViewManageable : NSObjectProtocol
{
    /// Collection view, that will be managed by DTCollectionViewManager
    var collectionView : UICollectionView? { get }
}

private var DTCollectionViewManagerAssociatedKey = "DTCollectionView Manager Associated Key"

/// Default implementation for `DTCollectionViewManageable` protocol, that will inject `manager` property to any object, that declares itself `DTCollectionViewManageable`.
extension DTCollectionViewManageable
{
    /// Lazily instantiated `DTCollectionViewManager` instance. When your collection view is loaded, call startManagingWithDelegate: method and `DTCollectionViewManager` will take over UICollectionView datasource and delegate. Any method, that is not implemented by `DTCollectionViewManager`, will be forwarded to delegate.
    /// - SeeAlso: `startManagingWithDelegate:`
    public var manager : DTCollectionViewManager
        {
        get {
            var object = objc_getAssociatedObject(self, &DTCollectionViewManagerAssociatedKey)
            if object == nil {
                object = DTCollectionViewManager()
                objc_setAssociatedObject(self, &DTCollectionViewManagerAssociatedKey, object, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            return object as! DTCollectionViewManager
        }
        set {
            objc_setAssociatedObject(self, &DTCollectionViewManagerAssociatedKey, newValue, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// `DTCollectionViewManager` manages some of `UICollectionView` datasource and delegate methods and provides API for managing your data models in the collection view. Any method, that is not implemented by `DTCollectionViewManager`, will be forwarded to delegate.
/// - SeeAlso: `startManagingWithDelegate:`
public class DTCollectionViewManager : NSObject {
    
    private var collectionView : UICollectionView! {
        return self.delegate?.collectionView
    }
    
    private weak var delegate : DTCollectionViewManageable?
    
    ///  Factory for creating cells and reusable views for UICollectionView
    private lazy var viewFactory: CollectionViewFactory = {
        precondition(self.collectionView != nil, "Please call manager.startManagingWithDelegate(self) before calling any other DTCollectionViewManager methods")
        return CollectionViewFactory(collectionView: self.collectionView)
    }()
    
    /// Bundle to search your xib's in. This can sometimes be useful for unit-testing. Defaults to NSBundle.mainBundle()
    public var viewBundle = NSBundle.mainBundle()
        {
        didSet {
            viewFactory.bundle = viewBundle
        }
    }
    
    /// Array of reactions for `DTCollectionViewManager`.
    /// - SeeAlso: `CollectionViewReaction`.
    private var collectionViewReactions = [CollectionViewReaction]()
    
    private func reactionOfReactionType(type: CollectionViewReactionType, forViewType viewType: _MirrorType? = nil, ofKind kind: String? = nil) -> CollectionViewReaction?
    {
        return self.collectionViewReactions.filter({ (reaction) -> Bool in
            return reaction.reactionType == type &&
                reaction.viewType?.summary == viewType?.summary &&
                reaction.kind == kind
        }).first
    }
    
    /// Implicitly unwrap storage property to `MemoryStorage`.
    /// - Warning: if storage is not MemoryStorage, will throw an exception.
    public var memoryStorage : MemoryStorage!
        {
            precondition(storage is MemoryStorage, "DTCollectionViewManager memoryStorage method should be called only if you are using MemoryStorage")
            
            return storage as! MemoryStorage
    }
    
    /// Storage, that holds your UICollectionView models. By default, it's `MemoryStorage` instance.
    /// - Note: When setting custom storage for this property, it will be automatically configured for using with UICollectionViewFlowLayout and it's delegate will be set to `DTCollectionViewManager` instance.
    /// - Note: Previous storage `delegate` property will be nilled out to avoid collisions.
    /// - SeeAlso: `MemoryStorage`, `CoreDataStorage`.
    public var storage : StorageProtocol = {
        let storage = MemoryStorage()
        storage.configureForCollectionViewFlowLayoutUsage()
        return storage
        }()
        {
        willSet {
            // explicit self is required due to known bug in Swift compiler - https://devforums.apple.com/message/1065306#1065306
            self.storage.delegate = nil
        }
        didSet {
            if let headerFooterCompatibleStorage = storage as? BaseStorage {
                headerFooterCompatibleStorage.configureForCollectionViewFlowLayoutUsage()
            }
            storage.delegate = self
        }
    }
    
    /// Call this method before calling any of `DTCollectionViewManager` methods.
    /// - Precondition: UICollectionView instance on `delegate` should not be nil.
    /// - Parameter delegate: Object, that has UICollectionView, that will be managed by `DTCollectionViewManager`.
    public func startManagingWithDelegate(delegate : DTCollectionViewManageable)
    {
        precondition(delegate.collectionView != nil,"Call startManagingWithDelegate: method only when UICollectionView has been created")
        
        self.delegate = delegate
        delegate.collectionView!.delegate = self
        delegate.collectionView!.dataSource = self
    }
    
    /// Call this method to retrieve model from specific UICollectionViewCell subclass.
    /// - Note: This method uses UICollectionView `indexPathForCell` method, that returns nil if cell is not visible. Therefore, if cell is not visible, this method will return nil as well.
    /// - SeeAlso: `StorageProtocol` method `objectForCell:atIndexPath:` - will return model even if cell is not visible
    public func objectForVisibleCell<T:ModelTransfer where T:UICollectionViewCell>(cell:T?) -> T.ModelType?
    {
        guard cell != nil else {  return nil }
        
        if let indexPath = self.collectionView.indexPathForCell(cell!) {
            return storage.objectAtIndexPath(indexPath) as? T.ModelType
        }
        return nil
    }
    
    /// Retrieve model of specific type at index path.
    /// - Parameter cellClass: UICollectionViewCell type
    /// - Parameter indexPath: NSIndexPath of the data model
    /// - Returns: data model that belongs to this index path.
    /// - Note: Method does not require cell to be visible, however it requires that storage really contains object of `ModelType` at specified index path, otherwise it will return nil.
    public func objectForCellClass<T:ModelTransfer where T:UICollectionViewCell>(cellClass: T.Type, atIndexPath indexPath: NSIndexPath) -> T.ModelType?
    {
        return self.storage.objectForCellClass(T.self, atIndexPath: indexPath)
    }
    
    /// Retrieve model of specific type for section index.
    /// - Parameter headerClass: UICollectionReusableView type
    /// - Parameter indexPath: NSIndexPath of the view
    /// - Returns: data model that belongs to this view
    /// - Note: Method does not require header to be visible, however it requires that storage really contains object of `ModelType` at specified section index, and storage to comply to `HeaderFooterStorageProtocol`, otherwise it will return nil.
    public func objectForHeaderClass<T:ModelTransfer where T:UICollectionReusableView>(headerClass: T.Type, atSectionIndex sectionIndex: Int) -> T.ModelType?
    {
        return self.storage.objectForHeaderClass(T.self, atSectionIndex: sectionIndex)
    }
    
    /// Retrieve model of specific type for section index.
    /// - Parameter footerClass: UICollectionReusableView type
    /// - Parameter indexPath: NSIndexPath of the view
    /// - Returns: data model that belongs to this view
    /// - Note: Method does not require footer to be visible, however it requires that storage really contains object of `ModelType` at specified section index, and storage to comply to `HeaderFooterStorageProtocol`, otherwise it will return nil.
    public func objectForFooterClass<T:ModelTransfer where T:UICollectionReusableView>(footerClass: T.Type, atSectionIndex sectionIndex: Int) -> T.ModelType?
    {
        return self.storage.objectForFooterClass(T.self, atSectionIndex: sectionIndex)
    }
    
    /// Retrieve model of specific type for section index.
    /// - Parameter supplementaryClass: UICollectionReusableView type
    /// - Parameter kind: supplementary kind
    /// - Parameter atSectionIndex: NSIndexPath of the view
    /// - Returns: data model that belongs to this view
    /// - Note: Method does not require supplementary view to be visible, however it requires that storage really contains object of `ModelType` at specified section index, and storage to comply to `SupplementaryStorageProcotol`, otherwise it will return nil.
    public func objectForSupplementaryClass<T:ModelTransfer where T:UICollectionReusableView>(supplementaryClass: T.Type, ofKind kind: String, atSectionIndex sectionIndex: Int) -> T.ModelType?
    {
        return (self.storage as? SupplementaryStorageProtocol)?.supplementaryModelOfKind(kind, sectionIndex: sectionIndex) as? T.ModelType
    }
}

// MARK: - Runtime forwarding
extension DTCollectionViewManager
{
    /// Any `UICollectionViewDatasource` and `UICollectionViewDelegate` method, that is not implemented by `DTCollectionViewManager` will be redirected to delegate, if it implements it.
    public override func forwardingTargetForSelector(aSelector: Selector) -> AnyObject? {
        return delegate
    }
    
    /// Any `UICollectionViewDatasource` and `UICollectionViewDelegate` method, that is not implemented by `DTCollectionViewManager` will be redirected to delegate, if it implements it.
    public override func respondsToSelector(aSelector: Selector) -> Bool {
        if self.delegate?.respondsToSelector(aSelector) ?? false {
            return true
        }
        return super.respondsToSelector(aSelector)
    }
}

// MARK: - View registration
extension DTCollectionViewManager
{
    /// Register mapping from model class to custom cell class. Method will automatically check for nib with the same name as `cellClass`. If it exists - nib will be registered instead of class.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter cellClass: Type of UICollectionViewCell subclass, that is being registered for using by `DTCollectionViewManager`
    public func registerCellClass<T:ModelTransfer where T: UICollectionViewCell>(cellClass:T.Type)
    {
        self.viewFactory.registerCellClass(cellClass)
    }
    
    /// This method combines registerCellClass and whenSelected: methods together.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter cellClass: Type of UICollectionViewCell subclass, that is being registered for using by `DTCollectionViewManager`
    /// - Parameter selectionClosure: closure to run when UICollectionViewCell is selected
    /// - Note: selectionClosure will be stored on `DTCollectionViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTCollectionViewManager` property in capture lists.
    /// - SeeAlso: `registerCellClass`, `whenSelected` methods
    public func registerCellClass<T:ModelTransfer where T:UICollectionViewCell>(cellClass: T.Type,
        whenSelected: (T,T.ModelType, NSIndexPath) -> Void)
    {
        viewFactory.registerCellClass(cellClass)
        self.whenSelected(cellClass, whenSelected)
    }
    
    /// Register mapping from model class to custom cell class using specific nib file.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter nibName: Name of xib file to use
    /// - Parameter cellClass: Type of UICollectionViewCell subclass, that is being registered for using by `DTCollectionViewManager`
    public func registerNibNamed<T:ModelTransfer where T: UICollectionViewCell>(nibName: String, forCellClass cellClass: T.Type)
    {
        viewFactory.registerNibNamed(nibName, forCellClass: cellClass)
    }
    
    /// Register mapping from model class to custom header view class. Method will automatically check for nib with the same name as `headerClass`. If it exists - nib will be registered instead of class.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter headerClass: Type of UICollectionViewCell subclass, that is being registered for using by `DTCollectionViewManager`
    public func registerHeaderClass<T:ModelTransfer where T: UICollectionReusableView>(headerClass : T.Type)
    {
        viewFactory.registerSupplementaryClass(T.self, forKind: UICollectionElementKindSectionHeader)
    }
    
    /// Register mapping from model class to custom footer view class. Method will automatically check for nib with the same name as `footerClass`. If it exists - nib will be registered instead of class.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter footerClass: Type of UICollectionReusableView subclass, that is being registered for using by `DTCollectionViewManager`
    public func registerFooterClass<T:ModelTransfer where T:UICollectionReusableView>(footerClass: T.Type)
    {
        viewFactory.registerSupplementaryClass(T.self, forKind: UICollectionElementKindSectionFooter)
    }
    
    /// Register mapping from model class to custom header class using specific nib file.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter nibName: Name of xib file to use
    /// - Parameter headerClass: Type of UICollectionReusableView subclass, that is being registered for using by `DTCollectionViewManager`
    public func registerNibNamed<T:ModelTransfer where T:UICollectionReusableView>(nibName: String, forHeaderClass headerClass: T.Type)
    {
        viewFactory.registerNibNamed(nibName, forSupplementaryClass: T.self, forKind: UICollectionElementKindSectionHeader)
    }
    
    /// Register mapping from model class to custom footer class using specific nib file.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter nibName: Name of xib file to use
    /// - Parameter footerClass: Type of UICollectionReusableView subclass, that is being registered for using by `DTCollectionViewManager`
    public func registerNibNamed<T:ModelTransfer where T:UICollectionReusableView>(nibName: String, forFooterClass footerClass: T.Type)
    {
        viewFactory.registerNibNamed(nibName, forSupplementaryClass: T.self, forKind: UICollectionElementKindSectionFooter)
    }
    
    /// Register mapping from model class to custom supplementary view class. Method will automatically check for nib with the same name as `supplementaryClass`. If it exists - nib will be registered instead of class.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter supplementaryClass: Type of UICollectionReusableView subclass, that is being registered for using by `DTCollectionViewManager`
    /// - Parameter kind: Supplementary kind
    public func registerSupplementaryClass<T:ModelTransfer where T:UICollectionReusableView>(supplementaryClass: T.Type, forKind kind: String)
    {
        viewFactory.registerSupplementaryClass(T.self, forKind: kind)
    }
    
    /// Register mapping from model class to custom supplementary class using specific nib file.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter nibName: Name of xib file to use
    /// - Parameter supplementaryClass: Type of UICollectionReusableView subclass, that is being registered for using by `DTCollectionViewManager`
    /// - Parameter kind: Supplementary kind
    public func registerNibNamed<T:ModelTransfer where T:UICollectionReusableView>(nibName: String, supplementaryClass: T.Type, forKind kind: String)
    {
        viewFactory.registerNibNamed(nibName, forSupplementaryClass: supplementaryClass, forKind: kind)
    }
    
}

// MARK: - Collection view reactions
public extension DTCollectionViewManager
{
    /// Define an action, that will be performed, when cell of specific type is selected.
    /// - Parameter cellClass: Type of UICollectionViewCell subclass
    /// - Parameter closure: closure to run when UICollectionViewCell is selected
    /// - Warning: Closure will be stored on `DTCollectionViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTCollectionViewManager` property in capture lists.
    public func whenSelected<T:ModelTransfer where T:UICollectionViewCell>(cellClass:  T.Type, _ closure: (T,T.ModelType, NSIndexPath) -> Void)
    {
        let reaction = CollectionViewReaction(.Selection)
        reaction.viewType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let indexPath = reaction.reactionData as? NSIndexPath,
                let cell = self?.collectionView.cellForItemAtIndexPath(indexPath) as? T,
                let model = self?.storage.objectAtIndexPath(indexPath) as? T.ModelType
            {
                closure(cell, model, indexPath)
            }
        }
        self.collectionViewReactions.append(reaction)
    }
    
    /// Define an action, that will be performed, when cell of specific type is selected.
    /// - Parameter methodPointer: pointer to `DTCollectionViewManageable` method with signature: (Cell, Model, NSIndexPath) closure to run when UICollectionViewCell is selected
    /// - Note: This method automatically breaks retain cycles, that can happen when passing method pointer somewhere.
    /// - Note: `ModelType` associated type. `DTCollectionViewManageable` instance is used to call selection event.
    public func cellSelection<T,U where T:ModelTransfer, T: UICollectionViewCell, U: DTCollectionViewManageable>( methodPointer: U -> (T,T.ModelType, NSIndexPath) -> Void )
    {
        let reaction = CollectionViewReaction(.Selection)
        reaction.viewType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let indexPath = reaction.reactionData as? NSIndexPath,
                let cell = self?.collectionView.cellForItemAtIndexPath(indexPath) as? T,
                let model = self?.storage.objectAtIndexPath(indexPath) as? T.ModelType,
                let delegate = self?.delegate as? U
            {
                methodPointer(delegate)(cell, model, indexPath)
            }
        }
        self.collectionViewReactions.append(reaction)
    }
    
    /// Define additional configuration action, that will happen, when UICollectionViewCell subclass is requested by UICollectionView. This action will be performed *after* cell is created and updateWithModel: method is called.
    /// - Parameter cellClass: Type of UICollectionViewCell subclass
    /// - Parameter closure: closure to run when UICollectionViewCell is being configured
    /// - Warning: Closure will be stored on `DTCollectionViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTCollectionViewManager` property in capture lists.
    public func configureCell<T:ModelTransfer where T: UICollectionViewCell>(cellClass:T.Type, _ closure: (T, T.ModelType, NSIndexPath) -> Void)
    {
        let reaction = CollectionViewReaction(.CellConfiguration)
        reaction.viewType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let configuration = reaction.reactionData as? ViewConfiguration,
                let view = configuration.view as? T,
                let model = self?.storage.objectAtIndexPath(configuration.indexPath) as? T.ModelType
            {
                closure(view, model, configuration.indexPath)
            }
        }
        self.collectionViewReactions.append(reaction)
    }
    
    /// Define an action, that will be performed, when cell of specific type is configured.
    /// - Parameter methodPointer: pointer to `DTCollectionViewManageable` method with signature: (Cell, Model, NSIndexPath) closure to run when UICollectionViewCell is configured
    /// - Note: This method automatically breaks retain cycles, that can happen when passing method pointer somewhere.
    /// - Note: `DTCollectionViewManageable` instance is used to call selection event.
    public func cellConfiguration<T,U where T:ModelTransfer, T: UICollectionViewCell, U: DTCollectionViewManageable>( methodPointer: U -> (T,T.ModelType, NSIndexPath) -> Void )
    {
        let reaction = CollectionViewReaction(.CellConfiguration)
        reaction.viewType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let indexPath = reaction.reactionData as? NSIndexPath,
                let cell = self?.collectionView.cellForItemAtIndexPath(indexPath) as? T,
                let model = self?.storage.objectAtIndexPath(indexPath) as? T.ModelType,
                let delegate = self?.delegate as? U
            {
                methodPointer(delegate)(cell, model, indexPath)
            }
        }
        self.collectionViewReactions.append(reaction)
    }
    
    /// Define additional configuration action, that will happen, when UICollectionReusableView header subclass is requested by UICollectionView. This action will be performed *after* header is created and updateWithModel: method is called.
    /// - Parameter headerClass: Type of UICollectionReusableView subclass
    /// - Parameter closure: closure to run when UICollectionReusableView is being configured
    /// - Warning: Closure will be stored on `DTCollectionViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTCollectionViewManager` property in capture lists.
    public func configureHeader<T:ModelTransfer where T: UICollectionReusableView>(headerClass: T.Type, _ closure: (T, T.ModelType, Int) -> Void)
    {
        self.configureSupplementary(T.self, ofKind: UICollectionElementKindSectionHeader, closure)
    }
    
    /// Define additional configuration action, that will happen, when UICollectionReusableView footer subclass is requested by UICollectionView. This action will be performed *after* footer is created and updateWithModel: method is called.
    /// - Parameter footerClass: Type of UICollectionReusableView subclass
    /// - Parameter closure: closure to run when UICollectionReusableView is being configured
    /// - Warning: Closure will be stored on `DTCollectionViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTCollectionViewManager` property in capture lists.
    public func configureFooter<T:ModelTransfer where T: UICollectionReusableView>(footerClass: T.Type, _ closure: (T, T.ModelType, Int) -> Void)
    {
        self.configureSupplementary(T.self, ofKind: UICollectionElementKindSectionFooter, closure)
    }
    
    /// Define additional configuration action, that will happen, when UICollectionReusableView supplementary subclass is requested by UICollectionView. This action will be performed *after* supplementary is created and updateWithModel: method is called.
    /// - Parameter supplementaryClass: Type of UICollectionReusableView subclass
    /// - Parameter closure: closure to run when UICollectionReusableView is being configured
    /// - Warning: Closure will be stored on `DTCollectionViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTCollectionViewManager` property in capture lists.
    public func configureSupplementary<T:ModelTransfer where T: UICollectionReusableView>(supplementaryClass: T.Type, ofKind kind: String, _ closure: (T,T.ModelType,Int) -> Void)
    {
        let reaction = CollectionViewReaction(.SupplementaryConfiguration)
        reaction.kind = kind
        reaction.viewType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let configuration = reaction.reactionData as? ViewConfiguration,
                let view = configuration.view as? T,
                let headerStorage = self?.storage as? HeaderFooterStorageProtocol,
                let model = headerStorage.headerModelForSectionIndex(configuration.indexPath.section) as? T.ModelType
            {
                closure(view, model, configuration.indexPath.section)
            }
        }
        self.collectionViewReactions.append(reaction)
    }
    
    /// Define additional configuration action, that will happen, when UICollectionReusableView header subclass is requested by UICollectionView. This action will be performed *after* supplementary is created and updateWithModel: method is called.
    /// - Parameter methodPointer: function to run when UICollectionReusableView header is being configured
    /// - Note: This method automatically breaks retain cycles, that can happen when passing method pointer somewhere.
    /// - Note: `DTCollectionViewManageable` instance is used to call configuration event.
    public func headerConfiguration<T,U where T:ModelTransfer, T: UICollectionReusableView, U: DTCollectionViewManageable>(kind kind: String, _ methodPointer: U -> (T,T.ModelType, Int) -> Void)
    {
        supplementaryConfiguration(kind: UICollectionElementKindSectionHeader, methodPointer)
    }
    
    /// Define additional configuration action, that will happen, when UICollectionReusableView footer subclass is requested by UICollectionView. This action will be performed *after* supplementary is created and updateWithModel: method is called.
    /// - Parameter methodPointer: function to run when UICollectionReusableView footer is being configured
    /// - Note: This method automatically breaks retain cycles, that can happen when passing method pointer somewhere.
    /// - Note: `DTCollectionViewManageable` instance is used to call configuration event.
    public func footerConfiguration<T,U where T:ModelTransfer, T: UICollectionReusableView, U: DTCollectionViewManageable>(kind kind: String, _ methodPointer: U -> (T,T.ModelType, Int) -> Void)
    {
        supplementaryConfiguration(kind: UICollectionElementKindSectionFooter, methodPointer)
    }
    
    /// Define additional configuration action, that will happen, when UICollectionReusableView supplementary subclass is requested by UICollectionView. This action will be performed *after* supplementary is created and updateWithModel: method is called.
    /// - Parameter kind: Kind of UICollectionReusableView subclass
    /// - Parameter methodPointer: function to run when UICollectionReusableView is being configured
    /// - Note: This method automatically breaks retain cycles, that can happen when passing method pointer somewhere.
    /// - Note: `DTCollectionViewManageable` instance is used to call configuration event.
    public func supplementaryConfiguration<T,U where T:ModelTransfer, T: UICollectionReusableView, U: DTCollectionViewManageable>(kind kind: String, _ methodPointer: U -> (T,T.ModelType, Int) -> Void)
    {
        let reaction = CollectionViewReaction(.SupplementaryConfiguration)
        reaction.kind = kind
        reaction.viewType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let configuration = reaction.reactionData as? ViewConfiguration,
                let view = configuration.view as? T,
                let headerStorage = self?.storage as? HeaderFooterStorageProtocol,
                let model = headerStorage.headerModelForSectionIndex(configuration.indexPath.section) as? T.ModelType,
                let delegate = self?.delegate as? U
            {
                methodPointer(delegate)(view, model, configuration.indexPath.section)
            }
        }
        self.collectionViewReactions.append(reaction)
    }
    
    /// Perform action before content will be updated.
    @available(*, unavailable, message="Adopt DTCollectionViewContentUpdatable protocol on your DTCollectionViewManageable instance instead")
    public func beforeContentUpdate(block: () -> Void )
    {
    }
    
    /// Perform action after content is updated.
    @available(*, unavailable, message="Adopt DTCollectionViewContentUpdatable protocol on your DTCollectionViewManageable instance instead")
    public func afterContentUpdate(block : () -> Void )
    {
    }
}

// MARK : - UICollectionViewDataSource
extension DTCollectionViewManager : UICollectionViewDataSource
{
    public func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return storage.sections[section].numberOfObjects
    }
    
    public func numberOfSectionsInCollectionView(collectionView: UICollectionView) -> Int {
        return storage.sections.count
    }
    
    public func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
        let model = storage.objectAtIndexPath(indexPath)
        let cell = viewFactory.cellForModel(model, atIndexPath: indexPath)
        if let reaction = self.reactionOfReactionType(.CellConfiguration, forViewType: _reflect(cell.dynamicType)) {
            reaction.reactionData = ViewConfiguration(view: cell, indexPath:indexPath)
            reaction.perform()
        }
        return cell
    }
    
    public func collectionView(collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, atIndexPath indexPath: NSIndexPath) -> UICollectionReusableView
    {
        if let model = (self.storage as? SupplementaryStorageProtocol)?.supplementaryModelOfKind(kind, sectionIndex: indexPath.section) {
            let view = viewFactory.supplementaryViewOfKind(kind, forModel: model, atIndexPath: indexPath)
            if let reaction = self.reactionOfReactionType(.SupplementaryConfiguration, forViewType: _reflect(view.dynamicType), ofKind: kind) {
                reaction.reactionData = ViewConfiguration(view: view, indexPath:indexPath)
                reaction.perform()
            }
            return view
        }
        return UICollectionReusableView()
    }
}

// MARK : - UICollectionViewDelegateFlowLayout
extension DTCollectionViewManager : UICollectionViewDelegateFlowLayout
{
    public func collectionView(collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize
    {
        if let size = (self.delegate as? UICollectionViewDelegateFlowLayout)?.collectionView?(collectionView, layout: collectionViewLayout, referenceSizeForHeaderInSection: section) {
            return size
        }
        if let _ = (storage as? SupplementaryStorageProtocol)?.supplementaryModelOfKind(UICollectionElementKindSectionHeader, sectionIndex: section) {
            return (collectionViewLayout as! UICollectionViewFlowLayout).headerReferenceSize
        }
        return CGSizeZero
    }
    
    public func collectionView(collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
        if let size = (self.delegate as? UICollectionViewDelegateFlowLayout)?.collectionView?(collectionView, layout: collectionViewLayout, referenceSizeForFooterInSection: section) {
            return size
        }
        if let _ = (storage as? SupplementaryStorageProtocol)?.supplementaryModelOfKind(UICollectionElementKindSectionFooter, sectionIndex: section) {
            return (collectionViewLayout as! UICollectionViewFlowLayout).footerReferenceSize
        }
        return CGSizeZero
    }
    
    public func collectionView(collectionView: UICollectionView, didSelectItemAtIndexPath indexPath: NSIndexPath)
    {
        let cell = collectionView.cellForItemAtIndexPath(indexPath)!
        if let reaction = self.reactionOfReactionType(.Selection, forViewType: _reflect(cell.dynamicType)) {
            reaction.reactionData = indexPath
            reaction.perform()
        }
    }
}

public protocol DTCollectionViewContentUpdatable {
    func beforeContentUpdate()
    func afterContentUpdate()
}

public extension DTCollectionViewContentUpdatable where Self : DTCollectionViewManageable {
    func beforeContentUpdate() {}
    func afterContentUpdate() {}
}

// MARK : - StorageUpdating
extension DTCollectionViewManager : StorageUpdating
{
    public func storageDidPerformUpdate(update: StorageUpdate) {
        self.controllerWillUpdateContent()
        
        let sectionsToInsert = NSMutableIndexSet()
        for index in 0..<update.insertedSectionIndexes.count {
            if self.collectionView.numberOfSections() <= index {
                sectionsToInsert.addIndex(index)
            }
        }
        
        let sectionChanges = update.deletedSectionIndexes.count + update.insertedSectionIndexes.count + update.updatedSectionIndexes.count
        let itemChanges = update.deletedRowIndexPaths.count + update.insertedRowIndexPaths.count + update.updatedRowIndexPaths.count
        
        if self.shouldReloadCollectionViewToPreventInsertFirstItemIssueForUpdate(update) {
            self.storageNeedsReloading()
            return
        }
        // TODO - Check if historic workaround is needed.
        
        if sectionChanges > 0 {
            self.collectionView.performBatchUpdates({ () -> Void in
                self.collectionView.deleteSections(update.deletedSectionIndexes)
                self.collectionView.insertSections(update.insertedSectionIndexes)
                self.collectionView.reloadSections(update.updatedSectionIndexes)
                }, completion: nil)
        }
        
        if itemChanges > 0 && sectionChanges == 0 {
            self.collectionView.performBatchUpdates({ () -> Void in
                self.collectionView.deleteItemsAtIndexPaths(update.deletedRowIndexPaths)
                self.collectionView.insertItemsAtIndexPaths(update.insertedRowIndexPaths)
                }, completion: nil)
                self.collectionView.reloadItemsAtIndexPaths(update.updatedRowIndexPaths)
        }
        
        self.controllerDidUpdateContent()
    }
    
    /// Call this method, if you want UICollectionView to be reloaded, and beforeContentUpdate: and afterContentUpdate: closures to be called.
    public func storageNeedsReloading() {
        self.controllerWillUpdateContent()
        collectionView.reloadData()
        self.controllerDidUpdateContent()
    }
    
    func controllerWillUpdateContent()
    {
        (self.delegate as? DTCollectionViewContentUpdatable)?.beforeContentUpdate()
    }
    
    func controllerDidUpdateContent()
    {
        (self.delegate as? DTCollectionViewContentUpdatable)?.afterContentUpdate()
    }
}

// MARK: - CollectionViewStorageUpdating
extension DTCollectionViewManager : CollectionViewStorageUpdating
{
    public func performAnimatedUpdate(block: (UICollectionView) -> Void) {
        block(collectionView)
    }
}

// MARK: - Workarounds
private extension DTCollectionViewManager
{
    // This is to prevent a bug in UICollectionView from occurring.
    // The bug presents itself when inserting the first object or deleting the last object in a collection view.
    // http://stackoverflow.com/questions/12611292/uicollectionview-assertion-failure
    // http://stackoverflow.com/questions/13904049/assertion-failure-in-uicollectionviewdata-indexpathforitematglobalindex
    // This code should be removed once the bug has been fixed, it is tracked in OpenRadar
    // http://openradar.appspot.com/12954582
    func shouldReloadCollectionViewToPreventInsertFirstItemIssueForUpdate(update: StorageUpdate) -> Bool
    {
        var shouldReload = false
        for indexPath in update.insertedRowIndexPaths {
            if self.collectionView.numberOfItemsInSection(indexPath.section) == 0 {
                shouldReload = true
                break
            }
        }
        for indexPath in update.deletedRowIndexPaths {
            if self.collectionView.numberOfItemsInSection(indexPath.section) == 1 {
                shouldReload = true
                break
            }
        }
        
        if self.collectionView.window == nil {
            shouldReload = true
        }
        
        return shouldReload
    }
}