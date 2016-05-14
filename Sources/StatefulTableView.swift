//
//  StatefulTableView.swift
//  Demo
//
//  Created by Tim on 12/05/2016.
//  Copyright © 2016 timominous. All rights reserved.
//

import UIKit

public final class StatefulTableView: UIView {
  enum State {
    case Idle
    case InitialLoading
    case InitialLoadingTableView
    case EmptyOrInitialLoadError
    case LoadingFromPullToRefresh
    case LoadingMore

    var isLoading: Bool {
      switch self {
      case .InitialLoading: fallthrough
      case .InitialLoadingTableView: fallthrough
      case .LoadingFromPullToRefresh: fallthrough
      case .LoadingMore:
        return true
      default: return false
      }
    }

    var isInitialLoading: Bool {
      switch self {
      case .InitialLoading: fallthrough
      case .InitialLoadingTableView:
        return true
      default: return false
      }
    }
  }

  enum ViewMode {
    case Table
    case Static
  }

  private lazy var tableView = UITableView()
  public var internalTable: UITableView {
    return tableView
  }

  private lazy var staticContentView: UIView = { [unowned self] in
    let view = UIView(frame: self.bounds)
    view.backgroundColor = .whiteColor()
    view.hidden = true
    return view
  }()

  private lazy var refreshControl = UIRefreshControl()

  public var canPullToRefresh = false
  public var canLoadMore = false
  public var loadMoreTriggerThreshold: CGFloat = 64

  private var loadMoreViewIsErrorView = false
  private var lastLoadMoreError: NSError?
  private var watchForLoadMore = false

  private var state: State = .Idle

  private var viewMode: ViewMode = .Table {
    didSet {
      let hidden = viewMode == .Table

      guard staticContentView.hidden != hidden else { return }
      staticContentView.hidden = hidden
    }
  }

  public var statefulDelegate: StatefulTableDelegate?

  required public init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    commonInit()
  }

  public override init(frame: CGRect) {
    super.init(frame: frame)
    commonInit()
  }

  func commonInit() {
    addSubview(tableView)
    addSubview(staticContentView)
    
    refreshControl.addTarget(self,
      action: #selector(refreshControlValueChanged), forControlEvents: .ValueChanged)
    tableView.addSubview(refreshControl)
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    tableView.frame = bounds
    staticContentView.frame = bounds
  }
}

// MARK: Accessors
extension StatefulTableView {
  public var dataSource: UITableViewDataSource? {
    set { tableView.dataSource = newValue }
    get { return tableView.dataSource }
  }

  public var delegate: UITableViewDelegate? {
    set { tableView.delegate = newValue }
    get { return tableView.delegate }
  }
}

extension StatefulTableView {
  public func reloadData() {
    dispatch_async(dispatch_get_main_queue()) {
      self.tableView.reloadData()
    }
  }

  public func registerClass(cellClass: AnyClass?, forCellReuseIdentifier identifier: String) {
    tableView.registerClass(cellClass, forCellReuseIdentifier: identifier)
  }

  public func registerNib(nib: UINib?, forCellReuseIdentifier identifier: String) {
    tableView.registerNib(nib, forCellReuseIdentifier: identifier)
  }

  public func registerClass(aClass: AnyClass?, forHeaderFooterViewReuseIdentifier identifier: String) {
    tableView.registerClass(aClass, forHeaderFooterViewReuseIdentifier: identifier)
  }

  public func registerNib(nib: UINib?, forHeaderFooterViewReuseIdentifier identifier: String) {
    tableView.registerNib(nib, forHeaderFooterViewReuseIdentifier: identifier)
  }
}

// MARK: Pull to refresh
extension StatefulTableView {
  func refreshControlValueChanged() {
    if state != .LoadingFromPullToRefresh && !state.isLoading {
      if (!triggerPullToRefresh()) {
        refreshControl.endRefreshing()
      }
    }
  }

  public func triggerPullToRefresh() -> Bool {
    guard !state.isLoading && canPullToRefresh else { return false }

    self.setState(.LoadingFromPullToRefresh, updateView: false, error: nil)

    if let delegate = statefulDelegate {
      delegate.statefulTableViewWillBeginLoadingFromRefresh(self, handler: { [weak self](tableIsEmpty, errorOrNil) in
        self?.setHasFinishedLoadingFromPullToRefresh(tableIsEmpty, error: errorOrNil)
      })
    }

    refreshControl.beginRefreshing()

    return true
  }

  func setHasFinishedLoadingFromPullToRefresh(tableIsEmpty: Bool, error: NSError?) {
    guard state == .LoadingFromPullToRefresh else { return }

    refreshControl.endRefreshing()

    if tableIsEmpty {
      self.setState(.EmptyOrInitialLoadError, updateView: true, error: error)
    } else {
      self.setState(.Idle)
    }
  }
}

// MARK: Initial load
extension StatefulTableView {
  public func triggerInitialLoad() -> Bool {
    return triggerInitialLoad(false)
  }

  public func triggerInitialLoad(shouldShowTableView: Bool) -> Bool {
    guard !state.isLoading else { return false }

    if shouldShowTableView {
      self.setState(.InitialLoadingTableView)
    } else {
      self.setState(.InitialLoading)
    }

    if let delegate = statefulDelegate {
      delegate.statefulTableViewWillBeginInitialLoad(self, handler: { [weak self](tableIsEmpty, errorOrNil) in
        self?.setHasFinishedInitialLoad(tableIsEmpty, error: errorOrNil)
      })
    }

    return true
  }

  func setHasFinishedInitialLoad(tableIsEmpty: Bool, error: NSError?) {
    guard state == .InitialLoading || state == .InitialLoadingTableView else { return }

    if tableIsEmpty {
      self.setState(.EmptyOrInitialLoadError, updateView: true, error: error)
    } else {
      self.setState(.Idle)
    }
  }
}

// MARK: Load more
extension StatefulTableView {
  public func triggerLoadMore() {
    guard !state.isLoading else { return }

    loadMoreViewIsErrorView = false
    lastLoadMoreError = nil
    updateLoadMoreView()

    setState(.LoadingMore)

    if let delegate = statefulDelegate {
      delegate.statefulTableViewWillBeginLoadingMore(self, handler: { [weak self](canLoadMore, errorOrNil, showErrorView) in
        self?.setHasFinishedLoadingMore(canLoadMore, error: errorOrNil, showErrorView: showErrorView)
      })
    }
  }

  func updateLoadMoreView() {
    if watchForLoadMore {
      tableView.tableFooterView = viewForLoadingMore(withError: (loadMoreViewIsErrorView ? lastLoadMoreError : nil))
    } else {
      tableView.tableFooterView = UIView()
    }
  }

  func viewForLoadingMore(withError error: NSError?) -> UIView {
    if let view = statefulDelegate?.statefulTableViewView(self, forLoadMoreError: error) { return view }

    let container = UIView(frame: CGRect(origin: .zero, size: CGSize(width: tableView.bounds.width, height: 44)))

    if let error = error {
      let label = UILabel()
      label.text = error.localizedDescription
      label.font = UIFont.systemFontOfSize(12)
      label.textAlignment = .Center
      label.frame = container.bounds
      container.addSubview(label)
    } else {
      let activityIndicator = UIActivityIndicatorView(activityIndicatorStyle: .Gray)
      activityIndicator.frame.centerInFrame(container.bounds)
      activityIndicator.startAnimating()
      container.addSubview(activityIndicator)
    }

    return container
  }

  func setHasFinishedLoadingMore(canLoadMore: Bool, error: NSError?, showErrorView: Bool) {
    guard state == .LoadingMore else { return }

    self.canLoadMore = canLoadMore
    loadMoreViewIsErrorView = (error != nil) && showErrorView
    lastLoadMoreError = error

    if let _ = error {
      updateLoadMoreView()
    }

    setState(.Idle)
  }

  func watchForLoadMoreIfApplicable(watch: Bool) {
    var watch = watch

    if (watch && !canLoadMore) {
      watch = false
    }
    watchForLoadMore = watch
    updateLoadMoreView()

    triggerLoadMoreIfApplicable(tableView)
  }

  public func scrollViewDidScroll(scrollView: UIScrollView) {
    triggerLoadMoreIfApplicable(scrollView)
  }

  func triggerLoadMoreIfApplicable(scrollView: UIScrollView) {
    guard watchForLoadMore && !loadMoreViewIsErrorView else { return }

    let scrollPosition = scrollView.contentSize.height - scrollView.frame.size.height - scrollView.contentOffset.y
    if scrollPosition < loadMoreTriggerThreshold {
      triggerLoadMore()
    }
  }
}

// MARK: States
extension StatefulTableView {
  func setState(newState: State) {
    setState(newState, updateView: true, error: nil)
  }

  func setState(newState: State, error: NSError?) {
    setState(newState, updateView: true, error: error)
  }

  func setState(newState: State, updateView: Bool, error: NSError?) {
    state = newState

    switch state {
    case .InitialLoading:
      resetStaticContentView(withChildView: viewForInitialLoad)
    case .EmptyOrInitialLoadError:
      resetStaticContentView(withChildView: viewForEmptyInitialLoad(withError: error))
    default: break
    }

    switch state {
    case .Idle:
      watchForLoadMoreIfApplicable(true)
    case .EmptyOrInitialLoadError:
      watchForLoadMoreIfApplicable(false)
    default: break
    }

    if updateView {
      let mode: ViewMode

      switch state {
      case .InitialLoading: fallthrough
      case .EmptyOrInitialLoadError:
        mode = .Static
      default: mode = .Table
      }

      viewMode = mode
    }
  }
}

// MARK: Views
extension StatefulTableView {
  func resetStaticContentView(withChildView childView: UIView) {
    staticContentView.subviews.forEach { $0.removeFromSuperview() }
    staticContentView.addSubview(childView)

    childView.translatesAutoresizingMaskIntoConstraints = false

    let attributes: [NSLayoutAttribute] = [.Top, .Bottom, .Leading, .Trailing]
    let constraints = attributes.map {
      return NSLayoutConstraint(item: childView, attribute: $0, relatedBy: .Equal,
        toItem: staticContentView, attribute: $0, multiplier: 1, constant: 0)
    }
    
    staticContentView.addConstraints(constraints)
  }

  var viewForInitialLoad: UIView {
    if let view = statefulDelegate?.statefulTableViewViewForInitialLoad(self) {
      return view
    }

    let activityIndicatorView = UIActivityIndicatorView(activityIndicatorStyle: .Gray)
    activityIndicatorView.startAnimating()
    activityIndicatorView.frame.centerInFrame(staticContentView.bounds)

    return activityIndicatorView
  }

  func viewForEmptyInitialLoad(withError error: NSError?) -> UIView {
    if let view = statefulDelegate?.statefulTableViewView(self, forInitialLoadError: error) { return view }

    var frame = CGRect(origin: .zero, size: CGSize(width: staticContentView.bounds.width, height: 120))
    frame.centerInFrame(staticContentView.bounds)

    let container = UIView(frame: frame)

    let label = UILabel()
    label.textAlignment = .Center
    label.text = error?.localizedDescription ?? "No records found"
    label.sizeToFit()

    label.frame.origin.x = (container.bounds.width - label.bounds.width) * 0.5

    if let _ = error {
      let button = UIButton(type: .System)
      button.setTitle("Try Again", forState: .Normal)
      button.addTarget(self, action: #selector(triggerPullToRefresh), forControlEvents: .TouchUpInside)

      button.frame.size = CGSize(width: 130, height: 32)
      button.frame.origin.x = (container.bounds.width - button.bounds.width) * 0.5
      button.frame.origin.y = label.frame.maxY + 10

      container.addSubview(button)
    }

    container.addSubview(label)

    return container
  }
}