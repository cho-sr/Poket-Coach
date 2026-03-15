import ExecuTorch
import Foundation

enum ExecuTorchRunnerError: Error {
    case modelNotFound
    case invalidOutput
}

final class ExecuTorchRunner {
    private let module: Module

    init(modelName: String = "detector", fileExtension: String = "pte") throws {
        guard let modelPath = Bundle.main.path(forResource: modelName, ofType: fileExtension) else {
            throw ExecuTorchRunnerError.modelNotFound
        }

        module = Module(filePath: modelPath)
        try module.load("forward")
    }

    func predict(input: [Float], shape: [Int]) throws -> [Float] {
        let inputTensor = Tensor<Float>(input, shape: shape)

        // TODO:
        // If the model returns multiple tensors, parse all outputs here.
        let outputs = try module.forward(inputTensor)

        guard let outputTensor: Tensor<Float> = outputs.first?.tensor() else {
            throw ExecuTorchRunnerError.invalidOutput
        }

        return outputTensor.scalars()
    }
}
