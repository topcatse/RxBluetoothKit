//
//  PeripheralDetailsViewController.swift
//  RxBluetoothKit
//
//  Created by Kacper Harasim on 29.03.2016.
//  Copyright © 2016 CocoaPods. All rights reserved.
//

import UIKit
import CoreBluetooth
import RxBluetoothKit
import RxSwift

fileprivate let fileSvcId    = CBUUID(string: "00020000-2ff1-4355-ae68-bd2f575b2249")
fileprivate let cmdCharId    = CBUUID(string: "00020001-2ff1-4355-ae68-bd2f575b2249")
fileprivate let dataCharId   = CBUUID(string: "00020002-2ff1-4355-ae68-bd2f575b2249")
fileprivate let sizeCharId   = CBUUID(string: "00020003-2ff1-4355-ae68-bd2f575b2249")
fileprivate let statusCharId = CBUUID(string: "00020004-2ff1-4355-ae68-bd2f575b2249")
fileprivate enum FileTransferState : UInt8 { case lock = 1, idle, recv, wait, send, fail }

fileprivate let loggingDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

fileprivate func log(_ string: String) {
    let date = Date()
    let stringWithDate = "[\(loggingDateFormatter.string(from: date))] \(string)"
    print(stringWithDate)
}

class PeripheralServicesViewController: UIViewController {

    private let disposeBag = DisposeBag()
    private var scheduler: ConcurrentDispatchQueueScheduler!

    @IBOutlet weak var servicesTableView: UITableView!
    @IBOutlet weak var activityIndicatorView: UIActivityIndicatorView! {
        didSet {
            activityIndicatorView.hidesWhenStopped = true
            activityIndicatorView.isHidden = true
        }
    }
    @IBOutlet weak var connectionStateLabel: UILabel!

    var scannedPeripheral: ScannedPeripheral!
    var manager: BluetoothManager!
    private var connectedPeripheral: Peripheral?
    fileprivate var servicesList: [Service] = []
    fileprivate let serviceCellId = "ServiceCell"

    override func viewDidLoad() {
        super.viewDidLoad()
        servicesTableView.delegate = self
        servicesTableView.dataSource = self
        servicesTableView.estimatedRowHeight = 40.0
        servicesTableView.rowHeight = UITableViewAutomaticDimension
        let timerQueue = DispatchQueue(label: "com.polidea.rxbluetoothkit.timer")
        scheduler = ConcurrentDispatchQueueScheduler(queue: timerQueue)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard scannedPeripheral != nil else { return }
        title = "Connecting"
        manager.connect(scannedPeripheral.peripheral)
            .subscribe(onNext: { [weak self] in
                guard let `self` = self else { return }
                self.title = "Connected"
                self.activityIndicatorView.stopAnimating()
                self.connectedPeripheral = $0
                self.monitorDisconnection(for: $0)
                self.downloadServices(for: $0)
                self.sendFile(to: $0)
                }, onError: { [weak self] error in
                    self?.activityIndicatorView.stopAnimating()
            }).disposed(by: disposeBag)
        activityIndicatorView.isHidden = false
        activityIndicatorView.startAnimating()
    }

    private func monitorDisconnection(for peripheral: Peripheral) {
        manager.monitorDisconnection(for: peripheral)
            .subscribe(onNext: { [weak self] (peripheral) in
                let alert = UIAlertController(title: "Disconnected!", message: "Peripheral Disconnected", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                self?.present(alert, animated: true, completion: nil)
          }).disposed(by: disposeBag)
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let identifier = segue.identifier, let cell = sender as? UITableViewCell,
            identifier == "PresentCharacteristics" else { return }
        guard let characteristicsVc = segue.destination as? CharacteristicsController else { return }

        if let indexPath = servicesTableView.indexPath(for: cell) {
            characteristicsVc.service = servicesList[indexPath.row]
        }
    }

    private func downloadServices(for peripheral: Peripheral) {
        peripheral.discoverServices(nil)
            .subscribe(onNext: { services in
                self.servicesList = services
                self.servicesTableView.reloadData()
            }).disposed(by: disposeBag)
    }
    
    fileprivate func triggerValueRead(for characteristic: Characteristic) {
        log("Start read ...")
        characteristic.readValue()
            .timeout(2.0, scheduler: scheduler)
            .subscribeOn(MainScheduler.instance)
            .subscribe(
                onNext: { char in
                    let uuid = char.uuid.uuidString
                    let value = char.value?.hexadecimalString ?? "Empty"
                    log("uuid: \(uuid), value: \(value)")
                },
                onError: { error in
                    let uuid = characteristic.uuid.uuidString
                    log("Timeout uuid: \(uuid)") }
            ).addDisposableTo(disposeBag)
    }

    fileprivate func triggerValueWrite(for peripheral: Peripheral, data: Data, characteristic: Characteristic) {
        let uuids = characteristic.uuid.uuidString
        log("Start write \(uuids) ...")
        peripheral.writeValue(data, for: characteristic, type: CBCharacteristicWriteType.withResponse)
            .timeout(60.0, scheduler: scheduler)
            .subscribeOn(MainScheduler.instance)
            .subscribe(
                onNext: { char in
                    let uuid = char.uuid.uuidString
                    log("Wrote on uuid: \(uuid)")
                },
                onError: { error in
                    let uuid = characteristic.uuid.uuidString
                    log("Write timeout on uuid: \(uuid)") }
            ).addDisposableTo(disposeBag)
    }
    
    private func makeList(_ n:Int ) -> Data {
        var result:[UInt8] = []
        for _ in 0..<n {
            result.append(UInt8(arc4random_uniform(254) + 1))
        }
        return Data(bytes: result)
    }
    
    private func sendFile(to peripheral: Peripheral) {
        guard let service = peripheral.services?.first(where: { $0.uuid == fileSvcId }) else {return}
        guard let cmdChar = service.characteristics?.first(where: {$0.uuid == cmdCharId }) else {return}
        guard let dataChar = service.characteristics?.first(where: {$0.uuid == dataCharId }) else {return}
        guard let sizeChar = service.characteristics?.first(where: {$0.uuid == sizeCharId }) else {return}
        guard let statusChar = service.characteristics?.first(where: {$0.uuid == statusCharId }) else {return}
        
        triggerValueRead(for: statusChar)
        
        triggerValueWrite(for: peripheral, data: Data(bytes: [100, 200, 0, 0]), characteristic: sizeChar)
        
        triggerValueWrite(for: peripheral, data: Data(bytes: [1]), characteristic: cmdChar)
        
        triggerValueRead(for: statusChar)

        triggerValueWrite(for: peripheral, data: makeList(100+256*200), characteristic: dataChar)
    }
}

extension PeripheralServicesViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return servicesList.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: serviceCellId, for: indexPath)
        let service = servicesList[indexPath.row]
        if let cell = cell as? ServiceTableViewCell {
            cell.update(with: service)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return UIView(frame: .zero)
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "SERVICES"
    }
}

extension ServiceTableViewCell {
    func update(with service: Service) {
        self.isPrimaryLabel.text = service.isPrimary ? "True" : "False"
        self.uuidLabel.text = service.uuid.uuidString
    }
}
