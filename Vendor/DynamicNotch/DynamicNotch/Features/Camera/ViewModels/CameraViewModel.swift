//
//  CameraViewModel.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 5/19/26.
//

import SwiftUI
import AVFoundation
import Combine

enum CameraState {
    case unknown
    case ready
    case unavailable
}

final class CameraViewModel: ObservableObject {
    let session = AVCaptureSession()
    @Published var cameraState: CameraState = .unknown
    
    private let sessionQueue = DispatchQueue(label: "com.dynamicnotch.cameraSessionQueue")
    private var stopWorkItem: DispatchWorkItem?
    private var isConfigured = false
    private(set) var isPageVisible = false
    
    let previewLayer = AVCaptureVideoPreviewLayer()
    
    init() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }
    
    deinit {
        stopWorkItem?.cancel()
        previewLayer.session = nil
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }
    
    func checkPermissions() {
        isPageVisible = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard self?.isPageVisible == true else { return }
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.cameraState = .unavailable
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.cameraState = .unavailable
            }
        }
    }
    
    func setupCamera() {
        guard isPageVisible else { return }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isConfigured else { return }
            
            let captureSession = self.session
            captureSession.beginConfiguration()
            
            for input in captureSession.inputs {
                captureSession.removeInput(input)
            }
            
            guard let device = AVCaptureDevice.default(for: .video) else {
                captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.cameraState = .unavailable
                }
                return
            }
            
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if captureSession.canAddInput(input) {
                    captureSession.addInput(input)
                    self.isConfigured = true
                } else {
                    DispatchQueue.main.async {
                        self.cameraState = .unavailable
                    }
                }
            } catch {
                print("Failed to set up camera input: \(error)")
                DispatchQueue.main.async {
                    self.cameraState = .unavailable
                }
            }
            
            captureSession.commitConfiguration()
            
            DispatchQueue.main.async {
                guard self.isPageVisible else { return }
                withAnimation {
                    self.cameraState = self.isConfigured ? .ready : .unavailable
                }
            }
        }
    }
    
    func startSession() {
        guard isPageVisible, isConfigured else { return }
        stopWorkItem?.cancel()
        stopWorkItem = nil
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let captureSession = self.session
            
            if !captureSession.isRunning {
                DispatchQueue.main.async {
                    self.cameraState = .unknown
                }
                
                captureSession.startRunning()
                
                DispatchQueue.main.async {
                    guard self.isPageVisible else { return }
                    withAnimation {
                        self.cameraState = .ready
                    }
                }
            } else {
                DispatchQueue.main.async {
                    if self.cameraState != .ready {
                        withAnimation {
                            self.cameraState = .ready
                        }
                    }
                }
            }
        }
    }
    
    func stopSession() {
        isPageVisible = false
        stopWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        self.stopWorkItem = workItem
        sessionQueue.async(execute: workItem)
    }
}

class PreviewView: NSView {
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.addSublayer(previewLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        previewLayer?.frame = self.bounds
    }
}
