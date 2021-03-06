//
//  LocalReceiptProvider.swift
//  SubscriptioMonitor
//
//  Created by Paul Wilkinson on 4/11/16.
//  Copyright © 2016 Paul Wilkinson. All rights reserved.
//

import Foundation
import StoreKit

/**
 
 LocalReceiptProvider retrieves the local receipt from the device. If the local receipt cannot be retrieved, it will 
 request a receipt refresh using `StoreKit`
 
 - Authors: Paul Wilkinson
 */

public class LocalReceiptProvider: NSObject, ReceiptProvider {
    
    fileprivate var receiptRefreshAttemped = false
    fileprivate var handler: ReceiptProvider.ReceiptHandler?
    
    /**
      Request the local receipt.
      - parameter handler: A closure to be invoked, either with the receipt `Data` or an `Error`
      - parameter data: The receipt data
      - parameter error: An error if receipt fetch/refresh failed
     */
    
    public func getReceipt(handler: @escaping (_ data: Data?, _ error: Error?) -> (Void)) {
        if let receiptURL = Bundle.main.appStoreReceiptURL {
            self.receiptRefreshAttemped = false                 // clear receipt refresh flag
            
            do {
                
                let receipt = try Data(contentsOf: receiptURL)
                handler(receipt, nil)
                self.handler = nil
            
            } catch {
                if self.receiptRefreshAttemped {
                    let error = ReceiptProviderError.fetchFailed(rootError: nil)
                    handler(nil, error)
                    self.handler = nil
                    self.receiptRefreshAttemped = false     // Try again next time
                } else {
                    self.receiptRefreshAttemped = true      // Indicate that we are trying to refresh the receipt
                    let refreshRequest = SKReceiptRefreshRequest()
                    self.handler = handler
                    refreshRequest.delegate = self
                    refreshRequest.start()
                }
            }
            
        } else {
            handler(nil,SubscriptionMonitorError.noReceiptAvailable(rootError: nil))
            self.handler = nil
        }
    }
}

extension LocalReceiptProvider: SKRequestDelegate {
    
    public func requestDidFinish(_ request: SKRequest) {
        self.getReceipt(handler: self.handler!)  // Now that we have the receipt, try and refresh the subscriptions
    }
    
    public func request(_ request: SKRequest, didFailWithError error: Error) {
        let receiptError = SubscriptionMonitorError.noReceiptAvailable(rootError:error)
        self.handler?(nil,receiptError)
        self.handler = nil
        self.receiptRefreshAttemped = false     // Try again next time
    }
}
