import Vision
import CoreImage
import UIKit

struct DetectedFace {
    let boundingBox: CGRect // Normalized [0, 1]
    let landmarks5: [CGPoint] // Pixel coordinates: [leftEye, rightEye, nose, leftMouth, rightMouth]
    let confidence: Float
}

final class VisionFaceTracker {
    
    private let sequenceHandler = VNSequenceHandler()
    
    // Standard InSwapper 128x128 destination 5-points
    static let inswapperDst128: [CGPoint] = [
        CGPoint(x: 46.2946, y: 51.6963), // Left eye
        CGPoint(x: 81.5318, y: 51.5014), // Right eye
        CGPoint(x: 64.0252, y: 71.7366), // Nose tip
        CGPoint(x: 49.5493, y: 92.3655), // Left mouth corner
        CGPoint(x: 78.7299, y: 92.2041)  // Right mouth corner
    ]
    
    // Standard ArcFace 112x112 destination 5-points
    static let arcfaceDst112: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041)
    ]
    
    func detectFace(in pixelBuffer: CVPixelBuffer) -> DetectedFace? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        
        let request = VNDetectFaceLandmarksRequest()
        request.preferBackgroundProcessing = false
        
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
            guard let observation = request.results?.first as? VNFaceObservation,
                  let landmarks = observation.landmarks else {
                return nil
            }
            
            return parseObservation(observation, landmarks: landmarks, imageWidth: width, imageHeight: height)
        } catch {
            return nil
        }
    }
    
    func detectFace(in image: UIImage) -> DetectedFace? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFaceObservation,
                  let landmarks = observation.landmarks else {
                return nil
            }
            return parseObservation(observation, landmarks: landmarks, imageWidth: width, imageHeight: height)
        } catch {
            return nil
        }
    }
    
    private func parseObservation(_ observation: VNFaceObservation, landmarks: VNFaceLandmarks2D, imageWidth: CGFloat, imageHeight: CGFloat) -> DetectedFace? {
        let box = observation.boundingBox
        
        // Convert normalized Vision coordinates (Y is inverted) to image pixel coordinates
        func toPixel(_ point: CGPoint) -> CGPoint {
            let px = (box.origin.x + point.x * box.width) * imageWidth
            let py = (1.0 - (box.origin.y + point.y * box.height)) * imageHeight
            return CGPoint(x: px, y: py)
        }
        
        guard let leftEyePoints = landmarks.leftEye?.normalizedPoints, !leftEyePoints.isEmpty,
              let rightEyePoints = landmarks.rightEye?.normalizedPoints, !rightEyePoints.isEmpty,
              let nosePoints = landmarks.noseCrest?.normalizedPoints ?? landmarks.nose?.normalizedPoints, !nosePoints.isEmpty,
              let outerLips = landmarks.outerLips?.normalizedPoints, outerLips.count >= 2 else {
            return nil
        }
        
        // Average coordinates for center of eyes
        let leftEyeCenter = leftEyePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let avgLeftEye = CGPoint(x: leftEyeCenter.x / CGFloat(leftEyePoints.count), y: leftEyeCenter.y / CGFloat(leftEyePoints.count))
        
        let rightEyeCenter = rightEyePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let avgRightEye = CGPoint(x: rightEyeCenter.x / CGFloat(rightEyePoints.count), y: rightEyeCenter.y / CGFloat(rightEyePoints.count))
        
        let noseTip = nosePoints.last!
        
        // Outer lips: index 0 is left corner, middle index is right corner in Vision
        let leftMouth = outerLips.first!
        let rightMouth = outerLips[outerLips.count / 2]
        
        let p1 = toPixel(avgLeftEye)
        let p2 = toPixel(avgRightEye)
        let p3 = toPixel(noseTip)
        let p4 = toPixel(leftMouth)
        let p5 = toPixel(rightMouth)
        
        return DetectedFace(
            boundingBox: box,
            landmarks5: [p1, p2, p3, p4, p5],
            confidence: observation.confidence
        )
    }
    
    /**
     * Umeyama 2D similarity transform mapping 5 source landmarks to destination 5 landmarks
     */
    static func computeAffineTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        guard src.count == 5 && dst.count == 5 else { return .identity }
        
        var srcMeanX: CGFloat = 0, srcMeanY: CGFloat = 0
        var dstMeanX: CGFloat = 0, dstMeanY: CGFloat = 0
        
        for i in 0..<5 {
            srcMeanX += src[i].x
            srcMeanY += src[i].y
            dstMeanX += dst[i].x
            dstMeanY += dst[i].y
        }
        srcMeanX /= 5.0
        srcMeanY /= 5.0
        dstMeanX /= 5.0
        dstMeanY /= 5.0
        
        var sxx: CGFloat = 0, sxy: CGFloat = 0, syx: CGFloat = 0, syy: CGFloat = 0
        var srcVar: CGFloat = 0
        
        for i in 0..<5 {
            let sx = src[i].x - srcMeanX
            let sy = src[i].y - srcMeanY
            let dx = dst[i].x - dstMeanX
            let dy = dst[i].y - dstMeanY
            
            sxx += sx * dx
            sxy += sx * dy
            syx += sy * dx
            syy += sy * dy
            srcVar += sx * sx + sy * sy
        }
        
        let angle = atan2(sxy - syx, sxx + syy)
        let cosA = cos(angle)
        let sinA = sin(angle)
        
        let scale = srcVar > 1e-6 ? ((sxx + syy) * cosA + (sxy - syx) * sinA) / srcVar : 1.0
        
        let a = scale * cosA
        let b = -scale * sinA
        let c = scale * sinA
        let d = scale * cosA
        
        let tx = dstMeanX - (a * srcMeanX + b * srcMeanY)
        let ty = dstMeanY - (c * srcMeanX + d * srcMeanY)
        
        return CGAffineTransform(a: a, b: c, c: b, d: d, tx: tx, ty: ty)
    }
}
