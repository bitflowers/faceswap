import SwiftUI
import PhotosUI

struct PicsiLiveView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var swapEngine = InSwapperEngine()
    
    @State private var currentMode: String = "Live" // "Live" | "Video" | "VR"
    @State private var liveDisplayImage: UIImage?
    @State private var isPickerPresented = false
    @State private var selectedItem: PhotosPickerItem?
    
    @State private var isProcessing = false
    @State private var capturedResultImage: UIImage?
    @State private var isShowingResult = false
    @State private var timerText = "00:00:00"
    @State private var toastMessage: String?
    
    var body: some View {
        ZStack {
            Color(hex: "0F1117").ignoresSafeArea()
            
            VStack(spacing: 12) {
                // 1. Top Header Bar
                HStack {
                    Text("Picsi Live")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {}) {
                        Text("Classic\nImage & GIF ↗")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "9CA3AF"))
                            .multilineTextAlignment(.trailing)
                    }
                    
                    Spacer().frame(width: 12)
                    
                    Circle()
                        .fill(Color(hex: "262936"))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "person.crop.circle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 26)
                                .foregroundColor(.gray)
                        )
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                
                // 2. Camera Viewport
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.black)
                    
                    if let img = liveDisplayImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                    
                    // Top Center Timer: "00:00:00"
                    VStack {
                        HStack {
                            Spacer()
                            Text(timerText)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Spacer()
                        }
                        .padding(.top, 14)
                        
                        Spacer()
                    }
                    
                    // Bottom Right Camera Flip Button
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button(action: {
                                cameraManager.flipCamera()
                            }) {
                                Circle()
                                    .fill(Color.black.opacity(0.6))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: "camera.rotate.fill")
                                            .foregroundColor(.white)
                                            .font(.system(size: 20))
                                    )
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                
                // 3. Face Selection Carousel
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        // + Add Face Button
                        Button(action: {
                            isPickerPresented = true
                        }) {
                            Circle()
                                .fill(Color(hex: "262936"))
                                .frame(width: 58, height: 58)
                                .overlay(
                                    Image(systemName: "plus")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.white)
                                )
                        }
                        
                        // Face Items
                        ForEach(swapEngine.activeFaces) { face in
                            let isSelected = swapEngine.selectedFace?.id == face.id
                            Button(action: {
                                if isSelected {
                                    swapEngine.selectedFace = nil
                                    showToast("Face unselected")
                                } else {
                                    swapEngine.selectedFace = face
                                    showToast("Selected: \(face.name)")
                                }
                            }) {
                                Image(uiImage: face.thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 58, height: 58)
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(isSelected ? Color.white : Color.clear, lineWidth: 3)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                }
                
                // 4. Mode Switcher: Live | Video | VR
                HStack(spacing: 28) {
                    ForEach(["Live", "Video", "VR"], id: \.self) { mode in
                        Button(action: {
                            currentMode = mode
                        }) {
                            Text(mode)
                                .font(.system(size: 15, weight: currentMode == mode ? .bold : .medium))
                                .foregroundColor(currentMode == mode ? .white : Color(hex: "9CA3AF"))
                        }
                    }
                }
                .padding(.top, 4)
                
                // 5. Bottom Controls Bar (Library | Red Shutter | Adjust)
                HStack {
                    // Left: Library Thumbnail
                    Button(action: {
                        isPickerPresented = true
                    }) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: "262936"))
                            .frame(width: 48, height: 48)
                            .overlay(
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                            )
                    }
                    
                    Spacer()
                    
                    // Center: Red Shutter / Record Button
                    Button(action: {
                        capturePhoto()
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 76, height: 76)
                            
                            Circle()
                                .fill(Color(hex: "FF334B"))
                                .frame(width: 62, height: 62)
                        }
                    }
                    
                    Spacer()
                    
                    // Right: Adjust Icon
                    Button(action: {}) {
                        Circle()
                            .fill(Color(hex: "262936"))
                            .frame(width: 48, height: 48)
                            .overlay(
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                            )
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
            }
            
            // Toast notification
            if let msg = toastMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .clipShape(Capsule())
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
            }
        }
        .photosPicker(isPresented: $isPickerPresented, selection: $selectedItem, matching: .images)
        .onChange(of: selectedItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    if swapEngine.addFace(from: image, name: "Face \(swapEngine.activeFaces.count + 1)") != nil {
                        showToast("Face added! Look into camera")
                    } else {
                        showToast("No face detected in photo")
                    }
                }
            }
        }
        .onAppear {
            swapEngine.initialize()
            cameraManager.onFrameReceived = { buffer in
                if let selected = swapEngine.selectedFace {
                    if let swapped = swapEngine.processLiveFrame(pixelBuffer: buffer, targetFace: selected) {
                        DispatchQueue.main.async {
                            self.liveDisplayImage = swapped
                        }
                    }
                } else {
                    let ci = CIImage(cvPixelBuffer: buffer)
                    let ctx = CIContext()
                    if let cg = ctx.createCGImage(ci, from: ci.extent) {
                        let raw = UIImage(cgImage: cg)
                        DispatchQueue.main.async {
                            self.liveDisplayImage = raw
                        }
                    }
                }
            }
            cameraManager.start()
        }
        .onDisappear {
            cameraManager.stop()
        }
        .sheet(isPresented: $isShowingResult) {
            if let res = capturedResultImage {
                ResultView(image: res, onDismiss: { isShowingResult = false })
            }
        }
    }
    
    private func capturePhoto() {
        guard let current = liveDisplayImage else { return }
        capturedResultImage = current
        UIImageWriteToSavedPhotosAlbum(current, nil, nil, nil)
        isShowingResult = true
        showToast("Saved to iPhone Photos!")
    }
    
    private func showToast(_ text: String) {
        withAnimation {
            toastMessage = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                toastMessage = nil
            }
        }
    }
}

struct ResultView: View {
    let image: UIImage
    let onDismiss: () -> Void
    
    var body: some View {
        ZStack {
            Color(hex: "0F1117").ignoresSafeArea()
            
            VStack {
                HStack {
                    Button("Done", action: onDismiss)
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Picsi Swap", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.white)
                            .font(.system(size: 18))
                    }
                }
                .padding()
                
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding()
                
                Spacer()
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
