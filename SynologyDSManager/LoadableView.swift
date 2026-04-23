//
//  LoadableView.swift
//  TableDemo
//
//  Created by Gabriel Theodoropoulos.
//  Copyright © 2019 Appcoda. All rights reserved.
//

import Cocoa

/// `@MainActor`-constrained because the default `load(fromNIBNamed:)`
/// implementation in the extension below touches AppKit APIs that are
/// `@MainActor`-isolated (`addSubview`, layout anchors, autoresizing
/// mask). Conformers are always `NSView` subclasses in practice, which
/// are themselves `@MainActor`, so the annotation is accurate rather
/// than a new constraint.
@MainActor
protocol LoadableView: AnyObject {
    var mainView: NSView? { get set }
    func load(fromNIBNamed nibName: String) -> Bool
}


extension LoadableView where Self: NSView {
    func load(fromNIBNamed nibName: String) -> Bool {
        var nibObjects: NSArray?
        let nibName = NSNib.Name(stringLiteral: nibName)
        
        if Bundle.main.loadNibNamed(nibName, owner: self, topLevelObjects: &nibObjects) {
            guard let nibObjects = nibObjects else { return false }
            
            let viewObjects = nibObjects.filter { $0 is NSView }
            
            if viewObjects.count > 0 {
                guard let view = viewObjects[0] as? NSView else { return false }
                mainView = view
                self.addSubview(mainView!)
                
                mainView?.translatesAutoresizingMaskIntoConstraints = false
                mainView?.leadingAnchor.constraint(equalTo: self.leadingAnchor).isActive = true
                mainView?.trailingAnchor.constraint(equalTo: self.trailingAnchor).isActive = true
                mainView?.topAnchor.constraint(equalTo: self.topAnchor).isActive = true
                mainView?.bottomAnchor.constraint(equalTo: self.bottomAnchor).isActive = true
                
                return true
            }
        }
        
        return false
    }
    
}
