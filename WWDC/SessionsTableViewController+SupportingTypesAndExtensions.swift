//
//  SessionsTableViewController+SupportingTypesAndExtensions.swift
//  WWDC
//
//  Created by Allen Humphreys on 6/6/18.
//  Copyright © 2018 Guilherme Rambo. All rights reserved.
//

import ConfCore
import RealmSwift
import RxRealm
import RxSwift
import os.log

/// Conforming to this protocol means the type is capable
/// of uniquely identifying a `Session`
///
/// TODO: Move to ConfCore and make it "official"?
protocol SessionIdentifiable {
    var sessionIdentifier: String { get }
}

struct SessionIdentifier: SessionIdentifiable {
    let sessionIdentifier: String

    init(_ string: String) {
        sessionIdentifier = string
    }
}

extension SessionViewModel: SessionIdentifiable {
    var sessionIdentifier: String {
        return identifier
    }
}

protocol SessionsTableViewControllerDelegate: class {

    func sessionTableViewContextMenuActionWatch(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionUnWatch(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionFavorite(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionRemoveFavorite(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionDownload(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionCancelDownload(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionRevealInFinder(viewModels: [SessionViewModel])
}

extension Session {

    var isWatched: Bool {
        if let progress = progresses.first {
            return progress.relativePosition > Constants.watchedVideoRelativePosition
        }

        return false
    }
}

extension Array where Element == SessionRow {

    func index(of session: SessionIdentifiable) -> Int? {
        return index { row in
            guard case .session(let viewModel) = row.kind else { return false }

            return viewModel.identifier == session.sessionIdentifier
        }
    }

    func firstSessionRowIndex() -> Int? {
        return index { row in
            if case .session = row.kind {
                return true
            }
            return false
        }
    }

    func forEachSessionViewModel(_ body: (SessionViewModel) throws -> Void) rethrows {
        try forEach {
            if case .session(let viewModel) = $0.kind {
                try body(viewModel)
            }
        }
    }
}

final class FilterResults {

    static var empty: FilterResults {
        return FilterResults(storage: nil, query: nil)
    }

    /// This becomes an OperationQueue for aborting, tada
    private static let searchQueue = DispatchQueue(label: "Search", qos: .userInteractive)

    private let query: NSPredicate?

    let storage: Storage?

    private(set) var latestSearchResults: Results<Session>?

    var disposeBag = DisposeBag()
    let nowPlayingBag = DisposeBag()

    private var observerClosure: ((Results<Session>?) -> Void)?
    private var observerToken: NotificationToken?

    init(storage: Storage?, query: NSPredicate?) {
        self.storage = storage
        self.query = query

        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {

            appDelegate
                .coordinator
                .rxPlayerOwnerSessionIdentifier
                .subscribe(onNext: { [weak self] _ in
                    self?.bindResults()
                }).disposed(by: nowPlayingBag)
        }
    }

    func observe(with closure: @escaping (Results<Session>?) -> Void) {
        assert(observerClosure == nil)

        guard query != nil, storage != nil else {
            closure(nil)
            return
        }

        observerClosure = closure

        bindResults()
    }

    func bindResults() {
        guard let observerClosure = observerClosure else { return }
        guard let storage = storage, let query = query?.combinedWithCurrentlyPlayingSessionPredicate() else { return }

        disposeBag = DisposeBag()

        do {
            let realm = try Realm(configuration: storage.realmConfig)

            let objects = realm.objects(Session.self).filter(query)

            Observable
                .shallowObservable(from: objects, synchronousStart: true)
                .subscribe(onNext: { [weak self] in
                    self?.latestSearchResults = $0
                    observerClosure($0)
                }).disposed(by: disposeBag)
        } catch {
            observerClosure(nil)
            os_log("Failed to initialize Realm for searching: %{public}@",
                   log: .default,
                   type: .error,
                   String(describing: error))
            LoggingHelper.registerError(error, info: ["when": "Searching"])
        }
    }
}

fileprivate extension NSPredicate {

    fileprivate func combinedWithCurrentlyPlayingSessionPredicate() -> NSPredicate {

        var predicate = NSPredicate(format: predicateFormat)

        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
            let currentlyPlayingSession = appDelegate.coordinator.playerOwnerSessionIdentifier {

            // Keep the currently playing video in the list to ensure PIP can re-select it if needed
            predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [predicate, NSPredicate(format: "identifier == %@", currentlyPlayingSession)])
        }

        return predicate
    }

}

public extension ObservableType where E: NotificationEmitter {

    /**
     Returns an `Observable<E>` that emits each time elements are added or removed from the collection.
     The observable emits an initial value upon subscription.

     - parameter from: A Realm collection of type `E`: either `Results`, `List`, `LinkingObjects` or `AnyRealmCollection`.
     - parameter synchronousStart: whether the resulting `Observable` should emit its first element synchronously (e.g. better for UI bindings)

     - returns: `Observable<E>`, e.g. when called on `Results<Model>` it will return `Observable<Results<Model>>`, on a `List<User>` it will return `Observable<List<User>>`, etc.
     */
    public static func shallowObservable(from collection: E, synchronousStart: Bool = true)
        -> Observable<E> {

            return Observable.create { observer in
                if synchronousStart {
                    observer.onNext(collection)
                }

                let token = collection.observe { changeset in

                    var value: E? = nil

                    switch changeset {
                    case .initial(let latestValue):
                        guard !synchronousStart else { return }
                        value = latestValue

                    case .update(let latestValue, let deletions, let insertions, _) where !deletions.isEmpty || !insertions.isEmpty:
                        value = latestValue

                    case .error(let error):
                        observer.onError(error)
                        return
                    default: ()
                    }

                    value.map(observer.onNext)
                }

                return Disposables.create {
                    token.invalidate()
                }
            }
    }
}
