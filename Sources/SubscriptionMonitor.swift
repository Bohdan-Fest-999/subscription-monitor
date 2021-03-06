//
//  SubscriptionMonitor.swift
//  SubscriptionMonitor
//
//  Created by Paul Wilkinson on 3/11/16.
//  Copyright © 2016 Paul Wilkinson. All rights reserved.
//

import Foundation
import StoreKit

/**
 **A framework for monitoring auto renewing subscriptions on iOS**
 
 SubscriptionMonitor automates the tasks required to validate in-app purchase receipts for auto-renewing subscriptions.
 It will periodically refresh the application receipt and validate it against your server.
 An NSNotification (and optionally a closure invocation) is used to let your app know that the receipt has been refreshed
 and that it should check for changes in subscriptions.
 
 - Authors: Paul Wilkinson
 
 */

public class SubscriptionMonitor: NSObject {
    
    //MARK:- Types
    
    /// A dictionary of `Subscription` objects, keyed by `ProductGroup`
    public typealias Subscriptions = [ProductGroup:Subscription]
    
    /**
     A closure to be invoked when subscriptions are updated.
     
     - parameter receipt: The `Receipt` that was validated
     - parameter subscriptions: The `Subscriptions` that are currently active
     - parameter error: The error, if any, that resulted from validating the receipt.
     
     - Note: If you have free products it is possible for both `Subscriptions?` and `Error?` to be non-nil
     */
    public typealias SubscriptionMonitorCallback = (_ receipt: Receipt?, _ subscriptions: Subscriptions?, _ error: Error?) -> (Void)
    
    //MARK:- Properties
    
    /// Subscription refresh interval (seconds)
    public var refreshInterval: Double {
        didSet {
            self.restartTimer()
        }
    }
    
    
    /// Validate receipts against production or sandbox
    public let useSandbox: Bool
    
    ///The `ReceiptValidator` in use by this `SubscriptionMonitor` instance
    public let validator: ReceiptValidator
    
    ///The last time the receipt and active subscriptions were validated
    fileprivate(set) public var lastValidationTime: Date?
    
    ///This `Notification` is issued when the subscription information has been refreshed
    public static let SubscriptionMonitorRefreshNotification = Notification.Name("SubscriptionMonitorRefreshNotification")
    
    
    ///The current version of this module
    public static let versionString = "1.0.9"
    
    ///The subscriptions that are currently active
    public var activeSubscriptions: Subscriptions? {
        get {
            return self.activeSubs
        }
    }
    
    ///The most recent `Receipt` that was validated
    public var latestReceipt: Receipt? {
        get {
            return self.receipt
        }
    }
    
    ///`true` if time-based receipt refreshing is enabled.  See `startRefreshing`, `stopRefreshing` and `refreshInterval`
    public var isRefreshEnabled: Bool {
        get {
            return self.isRefreshing
        }
    }
    
    // MARK:- Private properties
    
    fileprivate var refreshTimer: Timer?
    fileprivate var productGroups = Set<ProductGroup>()
    fileprivate var products = [String:Product]()
    
    fileprivate var receiptProvider: ReceiptProvider
    fileprivate var receipt: Receipt?
    fileprivate var isRefreshing = false {
        didSet {
            if oldValue != isRefreshing {
                self.restartTimer()
            }
        }
    }
    
    fileprivate var activeSubs:Subscriptions?
    
    fileprivate var receiptCallback: SubscriptionMonitorCallback?
    
    // MARK:- Initializers
    
    /**
     Initialise a new `SubscriptionMonitor`
     
     - Parameter validator: The `ReceiptValidator` that isused to validate the receipt
     - Parameter refreshInterval: The receipt refresh refreshInterval
     - Parameter useSandbox: `true` if the receipt should be validated against the Apple sandbox server
     - Parameter receiptProvider: A `ReceiptProvider` object.  By default a `LocalReceiptProvider` is used.
     
     - Returns: A new `SubscriptionMonitor`
     */
    
    public init(validator: ReceiptValidator, refreshInterval: Double = 3600, useSandbox: Bool = false, receiptProvider: ReceiptProvider = LocalReceiptProvider()) {
        self.validator = validator
        self.useSandbox = useSandbox
        self.refreshInterval = refreshInterval
        self.receiptProvider = receiptProvider
        super.init()
    }
    
    // MARK:- Public functions
    ///# Public functions
    
    /**
     Add the specified `ProductGroup` to this instance
     
     - parameter productGroup: The `ProductGroup` to be added
     */
    
    public func add(productGroup: ProductGroup) {
        self.productGroups.insert(productGroup)
        for product in productGroup.products {
            self.products[product.productID] = product
        }
    }
    
    /// Remove the specified `ProductGroup` from this instance
    ///
    /// - parameter productGroup: The `ProductGroup` to be removed
    ///
    
    public func remove(productGroup: ProductGroup) {
        for product in productGroup.products {
            self.products[product.productID] = nil
        }
        self.productGroups.remove(productGroup)
    }
    
    /// Start the periodic refreshing of the subscription information
    ///
    
    public func startRefreshing() {
        self.isRefreshing = true
    }
    
    /// Stop the periodic refreshing of the subscription information
    ///
    public func stopRefreshing() {
        self.isRefreshing = false
    }
    
    /// Force a refresh
    ///
    /// The refresh timer will be restarted
    public func refreshNow() {
        self.restartTimer()
        self.refreshSubscriptions()
    }
    
    /// Set the closure that will be invoked after the receipt/subscription update is triggered
    
    public func setUpdateCallback(_ callback:@escaping SubscriptionMonitorCallback) {
        self.receiptCallback = callback
    }
    
    /// Remove the callback closure
    public func clearUpdateCallback() {
        self.receiptCallback = nil
    }
    
    /// Determine active subscriptions from the current receipt at a specific time:
    /// - parameter at: The `Date` at which to determine active subscriptions
    /// - returns: `Subscriptions`, if any, that were active at that time
    public func activeSubscriptions(at: Date) -> Subscriptions? {
        
        do {
            return try self.process(self.receipt, at: at)
        }
        catch {
            return nil
        }
        
    }
    
    // MARK:- Private functions
    
    /**
     Restart the refresh Timer
     */
    
    fileprivate func restartTimer() {
        
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        
        if (self.isRefreshing) {
            
            self.refreshTimer = Timer.scheduledTimer(timeInterval: self.refreshInterval, target: self, selector: #selector(refreshSubscriptions), userInfo: nil, repeats: true)
        }
    }
    
    @objc fileprivate func refreshSubscriptions() {
        
        self.lastValidationTime = Date()
        
        self.receiptProvider.getReceipt { (data, error) -> (Void) in
            
            self.activeSubs = nil
            do {
                self.activeSubs = try self.process(nil, at:Date())   // There may be free active products
            } catch {}
            
            guard error == nil, let receiptData = data else {
                let validatorError = SubscriptionMonitorError.noReceiptAvailable(rootError: error)
                NotificationCenter.default.post(name: SubscriptionMonitor.SubscriptionMonitorRefreshNotification, object: self, userInfo: self.notificationDictionary(error: validatorError, receipt: nil, subscriptions: self.activeSubs))
                self.receiptCallback?(nil,self.activeSubs,validatorError)
                return
            }
            
            self.validator.validate(receipt: receiptData, forSubscriptionMonitor:self, completion: { (receipt, error) -> (Void) in
                
                guard error == nil, let validatedReceipt = receipt else {
                    let validatorError = SubscriptionMonitorError.validatorError(rootError: error)
                    NotificationCenter.default.post(name: SubscriptionMonitor.SubscriptionMonitorRefreshNotification, object: self, userInfo: self.notificationDictionary(error: validatorError, receipt: nil, subscriptions: self.activeSubs))
                    self.receiptCallback?(nil,self.activeSubs,validatorError)
                    return
                }
                
                self.receipt = nil
                
                do {
                    try self.activeSubs = self.process(validatedReceipt, at:Date())
                    self.receipt = validatedReceipt
                    self.receiptCallback?(self.receipt,self.activeSubs,nil)
                    NotificationCenter.default.post(name: SubscriptionMonitor.SubscriptionMonitorRefreshNotification, object: self, userInfo: self.notificationDictionary(error: nil, receipt: self.receipt, subscriptions: self.activeSubs))
                } catch {
                    
                    self.receiptCallback?(nil,self.activeSubs,error)
                    let validatorError = SubscriptionMonitorError.validatorError(rootError: error)
                    NotificationCenter.default.post(name: SubscriptionMonitor.SubscriptionMonitorRefreshNotification, object: self, userInfo: self.notificationDictionary(error: validatorError, receipt: nil, subscriptions: self.activeSubs))
                }
                
            })
        }
    }
    
    private func process(_ validateReceipt:Receipt?, at: Date) throws -> Subscriptions {
        
        var productsDict = [String:ProductGroup]()
        
        var activeProducts = Subscriptions()
        
        for productGroup in self.productGroups {
            for product in productGroup.products {
                productsDict[product.productID] = productGroup
                if product.isFree {
                    activeProducts[productGroup] = Subscription(inAppReceipt:nil, product:product)
                }
            }
        }
        
        if let latestInApp = validateReceipt?.latestInApp {
            for inapp in latestInApp {
                if inapp.isActive(on: at) {
                    guard let potentialProduct = self.products[inapp.productId] else {
                        throw SubscriptionMonitorError.invalidProduct
                    }
                    if let group = productsDict[inapp.productId] {
                        if let currentProduct = activeProducts[group] {
                            if potentialProduct.productLevel < currentProduct.product.productLevel {
                                activeProducts[group] = Subscription(inAppReceipt:inapp, product: potentialProduct)
                            }
                        } else {
                            activeProducts[group] = Subscription(inAppReceipt:inapp, product: potentialProduct)
                        }
                    } else {
                        throw SubscriptionMonitorError.invalidProduct
                    }
                }
            }
        }
        return activeProducts
    }
    
    func notificationDictionary(error: Error?, receipt: Receipt?, subscriptions: Subscriptions?) -> [String: Any] {
        var returnDict = [String:Any]()
        
        if let error = error {
            returnDict["Error"] = error as Any
        }
        
        if let receipt = receipt {
            returnDict["Receipt"] = receipt as Any
        }
        
        if let subscriptions = subscriptions {
            returnDict["Active"] = subscriptions as Any
        }
        
        return returnDict
    }
}

